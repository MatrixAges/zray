const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
pub const Kind = enum { list, optional };

pub fn append(graph: *Graph, payload: ?Graph.Id, kind: Kind, count: usize, span: zx.Span) zx.Error!Graph.Id {
    if (count == 0) return payload.?;

    if (comptime !@import("rx_options").generated_graph) {
        var child = payload orelse try graph.add(.unknown, span);

        for (0..count) |_| {
            child = try graph.add(switch (kind) {
                .list => .{ .list = child },
                .optional => .{ .optional = child },
            }, span);
        }

        return child;
    }

    const rows_count = std.math.add(usize, count, @intFromBool(payload == null)) catch return error.OutOfMemory;
    const reservation = try Nodes.reserve(graph, rows_count);
    const writer = @import("generated_rx_inference_containers");
    const Input = std.meta.Child(writer.Input);

    const container: Nodes.Kind = switch (kind) {
        .list => .List,
        .optional => .Optional,
    };

    const input: Input = .{
        .first = reservation.first,
        .end = reservation.rows.len,
        .payload = if (payload) |id| @backingInt(id) else null,
        .container = @backingInt(container),
        .unknown = @backingInt(Nodes.Kind.Unknown),
    };

    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buf, arena.allocator());

    const result = zx.columns.invoke(writer.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const parents = reservation.rows.items(.parent);
    const kinds = reservation.rows.items(.kind);
    const arguments = reservation.rows.items(.argument);
    const members = reservation.rows.items(.members);
    const spans = reservation.rows.items(.span);
    const alloweds = reservation.rows.items(.allowed);
    const fallbacks = reservation.rows.items(.fallback);

    for (result, reservation.first..) |item, index| {
        parents[index] = item.parent;
        kinds[index] = @fromBackingInt(@intCast(item.kind));
        arguments[index] = item.argument;
        members[index] = &.{};
        spans[index] = span;
        alloweds[index] = null;
        fallbacks[index] = null;
    }

    graph.nodes.len = reservation.rows.len;

    return @fromBackingInt(@intCast(reservation.rows.len - 1));
}
