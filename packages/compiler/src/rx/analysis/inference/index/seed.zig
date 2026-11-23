const zx = @import("zx");
const Graph = @import("../types.zig");
const Projection = @import("../index.zig").Projection;
const Target = @import("../sequences/target.zig");
const Projections = @import("../projections/seed.zig");

pub fn propagate(graph: *Graph, projection: Projection) zx.Error!bool {
    const target = Target.Seed.read(graph, projection.target);
    const route = target.indexRoute(projection.position);

    const child: Target.Seed.Child = switch (route) {
        .List => target.member(0),
        .Tuple => target.member(@intCast(projection.position.?)),
        else => .{ .value = 0, .declared = false },
    };

    return applySeed(graph, projection, route, child);
}

fn applySeed(graph: *Graph, projection: Projection, route: anytype, child: Target.Seed.Child) zx.Error!bool {
    const value = switch (route) {
        .Wait => return false,
        .List, .Tuple => try Target.child(graph, child.value, child.declared, projection.span),
        .String => try graph.scalar(.u8, projection.span),
        .MissingLiteral => return graph.reporter.fail(.type_mismatch, projection.index_span, "tuple indexing requires an integer literal"),
        .OutOfBounds => return graph.reporter.fail(.type_mismatch, projection.index_span, "tuple index is out of bounds"),
        .Invalid => return graph.reporter.fail(.type_mismatch, projection.span, "indexing requires a list, tuple or string"),
    };

    try graph.unify(value, projection.value, projection.span);

    return true;
}

pub fn replay(graph: *Graph) zx.Error!void {
    const indexes = graph.pending.indexes.slice();
    const resolved = indexes.items(.resolved);

    for (resolved, 0..) |*done, index| {
        if (!done.*) done.* = try propagate(graph, indexes.get(index));
    }
}

pub fn isResult(graph: *const Graph, id: Graph.Id) bool {
    const indexes = graph.pending.indexes.slice();

    for (indexes.items(.value), indexes.items(.resolved)) |value, resolved| {
        if (!resolved and graph.root(value) == graph.root(id)) return true;
    }

    return false;
}

pub fn defaultLists(graph: *Graph) zx.Error!bool {
    const indexes = graph.pending.indexes.slice();
    const index = Projections.firstPending(graph, indexes.items(.target));
    const projection = indexes.get(index orelse return false);
    const value = try graph.payload(projection.target, .list, projection.span);

    try graph.unify(value, projection.value, projection.span);

    return true;
}
