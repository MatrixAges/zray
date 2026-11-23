const zx = @import("zx");
const Graph = @import("../types.zig");
const Access = @import("../fields/seed.zig");
const length_name = @import("../fields/access.zig").length_name;

pub fn replay(graph: *Graph) zx.Error!void {
    const lengths = graph.pending.lengths.slice();

    for (lengths.items(.target), 0..) |target, index| {
        const root = graph.root(target);

        if (graph.nodes.items(.kind)[@backingInt(root)] == .Unknown) continue;

        const row = lengths.get(index);
        const value = try Access.at(graph, row.target, root, length_name, row.span);

        try graph.unify(value, row.value, row.span);
    }
}

pub fn validate(graph: *Graph) zx.Error!void {
    const lengths = graph.pending.lengths.slice();
    const index = firstPending(graph, lengths.items(.target)) orelse return;

    return graph.reporter.fail(.type_mismatch, lengths.items(.span)[index], "length alone cannot determine whether the input is a list, string or object");
}

pub fn firstPending(graph: *const Graph, targets: []const Graph.Id) ?usize {
    for (targets, 0..) |target, index| {
        if (graph.shape(target) == .unknown) return index;
    }

    return null;
}
