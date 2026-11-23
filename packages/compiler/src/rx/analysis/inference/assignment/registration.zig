const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const enabled = @import("rx_options").generated_graph;
const Index = if (enabled) []u32 else std.AutoHashMapUnmanaged([2]Graph.Id, void);

pub const Targets = union(enum) {
    repeated: Graph.Id,
    inferred: []const u32,
    declared: []const u32,
};

index: Index = if (enabled) &.{} else .empty,
pub fn expect(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    if (!enabled) return seed(graph, value, expected, span);

    try @import("registration/host.zig").expect(graph, value, expected, span);
}

pub const expectMany = @import("registration/host.zig").expectMany;

fn seed(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    const key = [2]Graph.Id{ graph.root(value), graph.root(expected) };

    if (key[0] == key[1] or graph.pending.assignment_keys.index.contains(key)) return;
    try graph.pending.assignments.ensureUnusedCapacity(graph.pending.allocator, 1);
    try graph.pending.assignment_keys.index.put(graph.pending.allocator, key, {});

    graph.pending.assignments.appendAssumeCapacity(.{ .value = key[0], .expected = key[1], .span = span });

    graph.revision += 1;
}
