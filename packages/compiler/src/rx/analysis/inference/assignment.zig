const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
pub const Base = @import("assignment/base.zig");
pub const validate = @import("assignment/validation.zig").validate;
pub const Edge = struct { value: Graph.Id, expected: Graph.Id, span: zx.Span, key: u64 = 0 };

pub fn materialize(graph: *Graph, base: Base, scratch: std.mem.Allocator) zx.Error!void {
    if (!@import("rx_options").generated_graph) {
        const depths = try @import("assignment/depth/seed.zig").solve(graph, scratch);

        return seedMaterialize(graph, base, depths);
    }

    return @import("assignment/application/materialization/host.zig").run(graph, base, scratch);
}

fn seedMaterialize(graph: *Graph, base: Base, depths: []const u64) zx.Error!void {
    for (0..depths.len) |index| {
        const id: Graph.Id = @fromBackingInt(@intCast(index));

        if (graph.root(id) != id) continue;

        const node = graph.nodeAt(index);

        if (node.shape != .unknown or node.allowed != null) continue;
        if (@import("index/seed.zig").isResult(graph, id)) continue;

        const value = (try base.representative(graph, id)) orelse continue;

        try apply(graph, index, value, depths[index]);
    }
}

pub fn apply(graph: *Graph, index: usize, payload: Graph.Id, depth: u64) zx.Error!void {
    const span = graph.nodes.items(.span)[index];
    const count = std.math.cast(usize, depth) orelse return error.OutOfMemory;
    const value = try graph.addContainers(payload, .optional, count, span);

    try graph.unify(@fromBackingInt(@intCast(index)), value, span);
}
