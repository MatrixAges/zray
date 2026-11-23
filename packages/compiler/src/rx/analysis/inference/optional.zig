const zx = @import("zx");
const Graph = @import("types.zig");
const seed = @import("optional/seed.zig");
const host = @import("optional/host.zig");
const generated = @import("rx_options").generated_graph;

pub fn hint(graph: *Graph, source: Graph.Id) zx.Error!?Graph.Id {
    return if (comptime generated) host.run(.Hint, graph, source) else seed.hint(graph, source);
}

pub fn payload(graph: *Graph, source: Graph.Id) zx.Error!Graph.Id {
    return if (comptime generated) (try host.run(.Payload, graph, source)).? else seed.payload(graph, source);
}
