const zx = @import("zx");
const Graph = @import("types.zig");
const optional_seed = @import("optional/seed.zig");

pub const Projection = struct { source: Graph.Id, value: Graph.Id, span: zx.Span };

pub fn read(graph: *Graph, source: Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    if (comptime @import("rx_options").generated_graph) return @import("non_null/read.zig").run(graph, source, span);
    if (try optional_seed.guarded(graph, source, span)) |value| return value;

    const value = try graph.add(.unknown, span);

    try graph.pending.nonnull.append(graph.pending.allocator, .{ .source = source, .value = value, .span = span });

    return value;
}

pub fn propagateSeed(graph: *Graph, infer_source: bool) zx.Error!void {
    const projections = graph.pending.nonnull.slice();

    for (0..projections.len) |index| {
        const projection = projections.get(index);

        if (try optional_seed.guarded(graph, projection.source, projection.span)) |value| {
            try graph.unify(projection.value, value, projection.span);
        } else if (infer_source and graph.shape(projection.value) != .unknown) {
            try infer(graph, projection);
        }
    }
}

fn infer(graph: *Graph, projection: Projection) zx.Error!void {
    const optional = try graph.add(.{ .optional = projection.value }, projection.span);

    try graph.unify(projection.source, optional, projection.span);
}
