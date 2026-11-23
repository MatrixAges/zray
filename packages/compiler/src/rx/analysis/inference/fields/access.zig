const zx = @import("zx");
const Graph = @import("../types.zig");

pub const length_name = "length";

pub fn field(graph: *Graph, target: Graph.Id, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    return at(graph, target, graph.root(target), name, span);
}

pub fn at(graph: *Graph, target: Graph.Id, root: Graph.Id, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    if (comptime !@import("rx_options").generated_graph) return @import("seed.zig").at(graph, target, root, name, span);

    return @import("host.zig").read(graph, target, root, name, span, false);
}

pub fn open(graph: *Graph, root: Graph.Id, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    return @import("host.zig").read(graph, root, root, name, span, true);
}
