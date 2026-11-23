const zx = @import("zx");
const Graph = @import("types.zig");
const Frame = @import("solve/host.zig").Frame;

pub fn finishSeed(graph: *Graph, resolver: *Graph.Resolver) zx.Error!void {
    var frame: Frame = .{
        .graph = graph,
        .resolver = resolver,
        .workspace = .init(graph.scratch),
        .closure = .init(graph.scratch),
    };

    defer frame.workspace.deinit();
    defer frame.closure.deinit();

    return @import("solve/seed.zig").run(&frame);
}
