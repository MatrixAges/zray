const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const rule = @import("generated_rx_scalar_literal");

pub fn append(graph: *Graph, text: []const u8, negative: bool, span: zx.Span) zx.Error!Graph.Id {
    const id = try graph.add(.unknown, span);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const lit = zx.columns.invoke(rule.executeValue, empty.allocator(), &.{ .text = text, .negative = negative }) catch unreachable;
    const rows = graph.nodes.slice();
    const index = @backingInt(id);

    rows.items(.allowed)[index] = @intCast(lit.allowed);
    rows.items(.fallback)[index] = @intCast(lit.fallback);

    graph.revision += 1;

    return id;
}
