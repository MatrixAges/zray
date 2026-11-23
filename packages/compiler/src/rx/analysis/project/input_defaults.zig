const std = @import("std");
const zx = @import("zx");
const Graph = @import("../inference/types.zig");
const Edges = std.MultiArrayList(@import("../inference/assignment.zig").Edge).Slice;

pub fn default(graph: *Graph, input: Graph.Id) zx.Error!void {
    const span = graph.nodes.items(.span)[@backingInt(input)];

    try graph.unify(input, try graph.scalar(.void, span), span);
}

pub fn seed(graph: *Graph, inputs: []const Graph.Id, fixed: []const bool) zx.Error!void {
    const edges: Edges = graph.pending.assignments.slice();

    for (inputs, fixed) |input, skip| {
        if (skip) continue;

        const root = graph.root(input);

        const referenced = for (edges.items(.value), edges.items(.expected)) |value, expected| {
            if (graph.root(value) == root or graph.root(expected) == root) break true;
        } else false;

        if (!referenced) try default(graph, input);
    }
}
