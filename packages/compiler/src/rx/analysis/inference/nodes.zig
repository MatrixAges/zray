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
    pub fn initialize(self: Reservation, shape_value: Encoded) void {
        const rule = @import("generated_rx_inference_nodes");
        const Input = std.meta.Child(rule.Input);
        const view = writable(self.rows);
        const parents = self.rows.items(.parent);

        const input: Input = .{
            .parents = @ptrCast(&parents),
            .columns = &view.borrow(std.meta.Child(@FieldType(Input, "columns"))),
            .shape = &.{ .kind = @backingInt(shape_value.kind), .argument = shape_value.argument, .members = shape_value.members },
            .first = self.first,
            .end = self.rows.len,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }
    pub fn publish(self: Reservation, graph: *Graph, span: zx.Span) void {
        @memset(self.rows.items(.span)[self.first..], span);
        self.finish(graph);
    }

    pub fn finish(self: Reservation, graph: *Graph) void {
        @memset(self.rows.items(.allowed)[self.first..], null);
        @memset(self.rows.items(.fallback)[self.first..], null);

        graph.nodes.len = self.rows.len;
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

pub fn append(graph: *Graph, value: Graph.Shape, span: zx.Span) zx.Error!Graph.Id {
    if (comptime enabled) {
        const reservation = try reserve(graph, 1);
        const topology = encode(value);

        reservation.initialize(topology);
        reservation.publish(graph, span);

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
    pub fn borrow(self: *const Writable, comptime Columns: type) Columns {
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
        .Object => .{ .object = Graph.Fields.fromValues(@ptrCast(rows.items(.members)[index])) },
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
