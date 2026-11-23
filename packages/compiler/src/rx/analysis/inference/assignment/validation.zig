const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
pub const Edges = std.MultiArrayList(@import("../assignment.zig").Edge).Slice;

pub fn validate(graph: *Graph, resolver: *Graph.Resolver) zx.Error!void {
    const edges = graph.pending.assignments.slice();

    if (!@import("rx_options").generated_graph) return seed(graph, edges);
    if (edges.len == 0) return;

    return @import("validation/host.zig").run(graph, resolver, edges);
}

fn seed(graph: *Graph, edges: Edges) zx.Error!void {
    const resolve = @import("../resolve/seed.zig").resolve;

    for (edges.items(.value), edges.items(.expected), edges.items(.span)) |source, target, span| {
        const actual = try resolve(graph, source, 0);
        const expected = try resolve(graph, target, 0);

        if (!seedAccepts(graph.types.items.view(), actual, expected)) return mismatch(graph, span);
    }
}

fn seedAccepts(table: zx.ir.TypeTable, actual: zx.ir.TypeId, expected: zx.ir.TypeId) bool {
    const optional = @backingInt(std.meta.Tag(zx.ir.Type).optional);
    var current = expected;

    while (current != actual) {
        const index = @backingInt(current);

        if (table.kinds[index] != optional) return false;

        current = @fromBackingInt(table.first[index]);
    }

    return true;
}

pub fn mismatch(graph: *const Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, "inferred value cannot be passed to the required type");
}
