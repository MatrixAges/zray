const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const rule = @import("generated_rx_inference_number");

pub fn append(graph: *Graph, text: []const u8, negative: bool, span: zx.Span) zx.Error!Graph.Id {
    const reservation = try Nodes.reserve(graph, 1);
    const Input = std.meta.Child(rule.Input);
    const Rows = std.meta.Child(@FieldType(Input, "rows"));
    const parents = reservation.rows.items(.parent);
    const topology = Nodes.writable(reservation.rows);

    const input: Input = .{
        .rows = &.{
            .first = reservation.first,
            .end = reservation.rows.len,
            .parents = @ptrCast(&parents),
            .columns = &topology.borrow(std.meta.Child(@FieldType(Rows, "columns"))),
            .shape = &.{ .kind = @backingInt(Nodes.Kind.Unknown), .argument = 0, .members = &.{} },
        },
        .token = &.{ .text = text, .negative = negative },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const restriction = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    const index = reservation.first;

    reservation.publish(graph, span);
    reservation.rows.items(.allowed)[index] = @intCast(restriction.allowed);
    reservation.rows.items(.fallback)[index] = @intCast(restriction.fallback);

    graph.revision += 1;

    return @fromBackingInt(@intCast(index));
}
