const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const enabled = @import("rx_options").generated_graph;
const generated = if (enabled) @import("generated_rx_object_view") else void;

pub const Kind = if (enabled) @FieldType(std.meta.Child(generated.Input), "kind") else enum {
    Unknown,
    Sequence,
    Known,
    Object,
    List,
    Optional,
    Tuple,
};

const Row = struct {
    parent: u32,
    kind: Kind,
    argument: u32,
    members: []const u32,
    span: zx.Span,
    allowed: ?u16 = null,
    fallback: ?u8 = null,
};

comptime {
    if (Graph.Mask.len > @bitSizeOf(u16)) @compileError("scalar constraints exceed the type graph mask column");
}

pub const Storage = std.MultiArrayList(Row);
pub const Encoded = struct { kind: Kind, argument: u32, members: []const u32 };

pub const Reservation = struct {
    rows: Storage.Slice,
    first: usize,
};

pub const Publication = struct {
    length: []usize,
    allowed: []?u16,
    fallback: []?u8,
    spans: []zx.Span,
    pub fn init(graph: *Graph, rows: Storage.Slice) Publication {
        return .{
            .length = (&graph.nodes.len)[0..1],
            .allowed = rows.items(.allowed),
            .fallback = rows.items(.fallback),
            .spans = rows.items(.span),
        };
    }
    pub fn storage(self: *Publication, comptime View: type) View {
        return .{
            .length = @ptrCast(&self.length),
            .allowed = @ptrCast(&self.allowed),
            .fallback = @ptrCast(&self.fallback),
        };
    }

    pub fn span(self: *Publication, comptime View: type, source: zx.Span) View {
        return .{ .rows = @ptrCast(&self.spans), .start = source.start, .end = source.end };
    }
};

pub fn reserve(graph: *Graph, count: usize) std.mem.Allocator.Error!Reservation {
    std.debug.assert(count != 0);

    const first = graph.nodes.len;
    const end = std.math.add(usize, first, count) catch return error.OutOfMemory;

    _ = std.math.cast(u32, end - 1) orelse return error.OutOfMemory;

    try graph.nodes.ensureTotalCapacity(graph.allocator, end);

    var rows = graph.nodes.slice();

    rows.len = end;

    return .{ .rows = rows, .first = first };
}

pub fn Append(comptime Input: type) type {
    return struct {
        parents: []u32,
        view: Writable,
        publication: Publication,
        columns: std.meta.Child(@FieldType(Input, "columns")),
        storage: std.meta.Child(@FieldType(Input, "storage")),
        source: std.meta.Child(@FieldType(Input, "span")),
        shape: std.meta.Child(@FieldType(Input, "shape")),
        pub fn bind(self: *@This(), input: *Input, graph: *Graph, reservation: Reservation, value: Graph.Shape, span: zx.Span) void {
            const topology = encode(value);

            self.parents = reservation.rows.items(.parent);
            self.view = writable(reservation.rows);
            self.publication = Publication.init(graph, reservation.rows);
            self.columns = self.view.borrow(@TypeOf(self.columns));
            self.storage = self.publication.storage(@TypeOf(self.storage));
            self.source = self.publication.span(@TypeOf(self.source), span);
            self.shape = .{ .kind = @backingInt(topology.kind), .argument = topology.argument, .members = topology.members };

            input.* = .{
                .parents = @ptrCast(&self.parents),
                .columns = &self.columns,
                .shape = &self.shape,
                .first = reservation.first,
                .end = reservation.rows.len,
                .storage = &self.storage,
                .span = &self.source,
            };
        }
    };
}

pub fn append(graph: *Graph, value: Graph.Shape, span: zx.Span) zx.Error!Graph.Id {
    if (comptime enabled) {
        const reservation = try reserve(graph, 1);
        const rule = @import("generated_rx_inference_nodes");
        const Input = std.meta.Child(rule.Input);
        var frame: Append(Input) = undefined;
        var input: Input = undefined;

        frame.bind(&input, graph, reservation, value, span);

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeIn(empty.allocator(), &input) catch unreachable;

        return @fromBackingInt(@intCast(reservation.first));
    }

    const parent = std.math.cast(u32, graph.nodes.len) orelse return error.OutOfMemory;

    try graph.nodes.append(graph.allocator, record(parent, value, span));

    return @fromBackingInt(parent);
}

pub const Writable = struct {
    kinds: []u8,
    arguments: []u32,
    members: [][]const u32,
    pub fn borrow(self: *Writable, comptime Columns: type) Columns {
        return .{
            .kinds = @ptrCast(&self.kinds),
            .arguments = @ptrCast(&self.arguments),
            .members = @ptrCast(&self.members),
        };
    }
};

pub fn writable(rows: Storage.Slice) Writable {
    comptime {
        if (@sizeOf(Kind) != @sizeOf(u8)) @compileError("inference kind column must store one byte per row");
    }

    return .{
        .kinds = std.mem.sliceAsBytes(rows.items(.kind)),
        .arguments = rows.items(.argument),
        .members = rows.items(.members),
    };
}

fn encode(value: Graph.Shape) Encoded {
    return .{
        .kind = switch (value) {
            .unknown => .Unknown,
            .sequence => .Sequence,
            .known => .Known,
            .object => .Object,
            .list => .List,
            .optional => .Optional,
            .tuple => .Tuple,
        },
        .argument = switch (value) {
            .known => |id| @backingInt(id),
            .list, .optional => |child| @backingInt(child),
            else => 0,
        },
        .members = switch (value) {
            .object => |fields| @ptrCast(fields.values()),
            .tuple => |members| @ptrCast(members),
            else => &.{},
        },
    };
}

fn record(parent: u32, value: Graph.Shape, span: zx.Span) Row {
    const topology = encode(value);

    return .{
        .parent = parent,
        .kind = topology.kind,
        .argument = topology.argument,
        .members = topology.members,
        .span = span,
    };
}

pub fn shape(rows: Storage.Slice, index: usize) Graph.Shape {
    return switch (rows.items(.kind)[index]) {
        .Unknown => .unknown,
        .Sequence => .sequence,
        .Known => .{ .known = @fromBackingInt(rows.items(.argument)[index]) },
        .Object => .{ .object = Graph.Fields.viewFromValues(@ptrCast(rows.items(.members)[index])) },
        .List => .{ .list = @fromBackingInt(rows.items(.argument)[index]) },
        .Optional => .{ .optional = @fromBackingInt(rows.items(.argument)[index]) },
        .Tuple => .{ .tuple = @ptrCast(rows.items(.members)[index]) },
    };
}

pub fn allowed(rows: Storage.Slice, index: usize) ?Graph.Mask {
    const bits = rows.items(.allowed)[index] orelse return null;

    return .{ .bits = .{ .mask = @intCast(bits) } };
}

pub fn get(rows: Storage.Slice, index: usize) Graph.Node {
    const fallback = rows.items(.fallback)[index];

    return .{
        .shape = shape(rows, index),
        .span = rows.items(.span)[index],
        .allowed = allowed(rows, index),
        .fallback = if (fallback) |code| @fromBackingInt(@intCast(code)) else null,
    };
}

pub fn setShape(rows: Storage.Slice, index: usize, value: Graph.Shape) void {
    const row = encode(value);

    rows.items(.kind)[index] = row.kind;
    rows.items(.argument)[index] = row.argument;
    rows.items(.members)[index] = row.members;
}
