const zx = @import("zx");
const Graph = @import("types.zig");

pub fn merge(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!void {
    if (comptime !@import("rx_options").generated_graph) return @import("unify/seed.zig").merge(graph, left, right, span, depth);

    return @import("unify/host.zig").merge(graph, left, right, span, depth);
}
