const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Access = @import("fields/access.zig");
const enabled = @import("rx_options").generated_graph;

pub const Length = struct { target: Graph.Id, value: Graph.Id, span: zx.Span };

pub fn applyLengths(graph: *Graph) zx.Error!void {
    const lengths = graph.pending.lengths.slice();
    const targets = lengths.items(.target);

    if (!enabled) {
        for (targets, 0..) |target, index| {
            const root = graph.root(target);

            if (graph.nodes.items(.kind)[@backingInt(root)] != .Unknown) try applyLength(graph, lengths.get(index), root);
        }

        return;
    }

    try @import("projections/host.zig").run(graph, lengths);
}

pub fn validateLengths(graph: *Graph) zx.Error!void {
    const lengths = graph.pending.lengths.slice();
    const index = firstPending(graph, lengths.items(.target)) orelse return;

    return graph.reporter.fail(.type_mismatch, lengths.items(.span)[index], "length alone cannot determine whether the input is a list, string or object");
}

pub fn firstPending(graph: *const Graph, targets: []const Graph.Id) ?usize {
    if (targets.len == 0) return null;
    if (!enabled) return seedPending(graph, targets);

    const scan = @import("generated_rx_projection_scan");
    const parents: []u32 = graph.parents();
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(scan.Input) = .{
        .targets = @ptrCast(targets),
        .kinds = graph.nodes.items(.kind),
        .parents = @ptrCast(&parents),
    };

    const result = zx.columns.invoke(scan.executeValue, empty.allocator(), &input) catch unreachable;

    return if (result) |row| @intCast(row) else null;
}

fn applyLength(graph: *Graph, projection: Length, root: Graph.Id) zx.Error!void {
    const value = try Access.at(graph, projection.target, root, Access.length_name, projection.span);

    try graph.unify(value, projection.value, projection.span);
}

fn seedPending(graph: *const Graph, targets: []const Graph.Id) ?usize {
    for (targets, 0..) |target, index| {
        if (graph.shape(target) == .unknown) return index;
    }

    return null;
}
