const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
pub const Base = @import("assignment/base.zig");
pub const validate = @import("assignment/validation.zig").validate;
pub const Edge = struct { value: Graph.Id, expected: Graph.Id, span: zx.Span, key: u64 = 0 };

pub fn materialize(graph: *Graph, base: Base, scratch: std.mem.Allocator) zx.Error!void {
    const depths = try @import("assignment/depth.zig").solve(graph, scratch);

    if (!@import("rx_options").generated_graph) return seedMaterialize(graph, base, depths);

    const generated = @import("generated_assignment_next_materialization");
    const deferred = try markDeferred(graph, scratch, depths.len);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var start: usize = 0;

    // Each merge keeps the current row as its root. Later roots can disappear but cannot acquire a deferred member.
    while (start < depths.len) {
        const nodes = graph.nodes.slice();
        const parents = graph.parents();

        const result = generated.executeState(empty.allocator(), .{
            .nodes = &.{ .kinds = nodes.items(.kind), .allowed = nodes.items(.allowed) },
            .deferred = .{ .items = deferred, .storage = .plain },
            .classes = &.{ .groups = base.parents, .representatives = base.representatives },
            .parents = @ptrCast(&parents),
            .next = start,
            .other = null,
            .limit = depths.len,
        }) catch unreachable;

        const other: Graph.Id = @fromBackingInt(result.other orelse break);
        start = @intCast(result.next);

        const index = start - 1;

        try apply(graph, index, other, depths[index]);
    }
}

fn markDeferred(graph: *const Graph, scratch: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]const u64 {
    const rows = graph.pending.indexes.slice();
    const resolved = rows.items(.resolved);

    if (std.mem.indexOfScalar(bool, resolved, false) == null) return &.{};

    const words = try scratch.alloc(u64, std.math.divCeil(usize, count, @bitSizeOf(u64)) catch unreachable);
    const parents = graph.parents();
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    @memset(words, 0);

    const mark = @import("generated_assignment_mark_deferred");

    const input: std.meta.Child(mark.Input) = .{
        .parents = @ptrCast(&parents),
        .values = @ptrCast(rows.items(.value)),
        .resolved = resolved,
        .words = @ptrCast(&words),
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
