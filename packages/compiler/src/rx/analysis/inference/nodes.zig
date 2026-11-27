const std = @import("std");
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
    span: @import("zx").Span,
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

pub fn append(graph: *Graph, value: Graph.Shape, span: @import("zx").Span) @import("zx").Error!Graph.Id {
    const parent = std.math.cast(u32, graph.nodes.len) orelse return error.OutOfMemory;

    try graph.nodes.append(graph.allocator, record(parent, value, span));

    return @fromBackingInt(parent);
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

fn record(parent: u32, value: Graph.Shape, span: @import("zx").Span) Row {
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
