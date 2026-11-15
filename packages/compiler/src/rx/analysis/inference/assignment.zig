const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Depth = @import("assignment/depth.zig");
pub const Base = @import("assignment/base.zig");
pub const validate = @import("assignment/validation.zig").validate;
pub const Edge = struct { value: Graph.Id, expected: Graph.Id, span: zx.Span, key: u64 = 0 };

pub fn materialize(graph: *Graph, base: Base, scratch: std.mem.Allocator) zx.Error!void {
    if (!@import("rx_options").generated_graph) {
        const depths = try @import("assignment/depth/seed.zig").solve(graph, scratch);

        return seedMaterialize(graph, base, depths);
    }

    const generated = @import("generated_assignment_next_materialization");
    const prepared = try Depth.prepare(graph, scratch);
    const deferred = try markDeferred(graph, scratch, prepared);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var start: usize = 0;

    // Each merge keeps the current row as its root. Later roots can disappear but cannot acquire a deferred member.
    while (start < prepared.depths.len) {
        const nodes = graph.nodes.slice();
        const parents = graph.parents();

        const input: std.meta.Child(generated.Input) = .{
            .nodes = &.{ .kinds = nodes.items(.kind), .allowed = nodes.items(.allowed) },
            .depths = prepared.depths,
            .deferred = deferred,
            .classes = &.{ .groups = base.parents, .representatives = base.representatives },
            .parents = @ptrCast(&parents),
            .next = start,
        };

        const result = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;
        const payload: Graph.Id = @fromBackingInt(result.payload orelse break);
        start = @intCast(result.next);

        try apply(graph, result.node, payload, result.layers);
    }
}

fn markDeferred(graph: *const Graph, scratch: std.mem.Allocator, prepared: Depth.Prepared) std.mem.Allocator.Error![]const u64 {
    if (prepared.deferred_words == 0) return &.{};

    const rows = graph.pending.indexes.slice();
    const words = try scratch.alloc(u64, prepared.deferred_words);
    const parents = graph.parents();
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    @memset(words, 0);

    const mark = @import("generated_assignment_mark_deferred");

    const input: std.meta.Child(mark.Input) = .{
        .parents = @ptrCast(&parents),
        .values = @ptrCast(rows.items(.value)),
        .resolved = rows.items(.resolved),
        .words = @ptrCast(&words),
        .first = prepared.first_deferred,
    };

    zx.columns.invoke(mark.executeValue, empty.allocator(), &input) catch unreachable;

    return words;
}

fn seedMaterialize(graph: *Graph, base: Base, depths: []const u64) zx.Error!void {
    for (0..depths.len) |index| {
        const id: Graph.Id = @fromBackingInt(@intCast(index));

        if (graph.root(id) != id) continue;

        const node = graph.nodeAt(index);

        if (node.shape != .unknown or node.allowed != null) continue;
        if (@import("index.zig").isResult(graph, id)) continue;

        const value = (try base.representative(graph, id)) orelse continue;

        try apply(graph, index, value, depths[index]);
    }
}

fn apply(graph: *Graph, index: usize, payload: Graph.Id, depth: u64) zx.Error!void {
    const span = graph.nodes.items(.span)[index];
    const count = std.math.cast(usize, depth) orelse return error.OutOfMemory;
    const value = try graph.addContainers(payload, .optional, count, span);

    try graph.unify(@fromBackingInt(@intCast(index)), value, span);
}
