const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");

pub const Prepared = struct {
    depths: []const u64,
    first_deferred: usize,
    deferred_words: usize,
};

pub fn prepare(graph: *Graph, scratch: std.mem.Allocator) zx.Error!Prepared {
    const rows = graph.nodes.slice();
    const assignments = graph.pending.assignments.slice();
    const left: []u32 = @ptrCast(assignments.items(.value));
    const right: []u32 = @ptrCast(assignments.items(.expected));
    const parents: []u32 = graph.parents();
    const depths = try scratch.alloc(u64, rows.len);
    const entry = @import("generated_assignment_materialization_plan");

    const input: std.meta.Child(entry.Input) = .{
        .depth = &.{
            .graph = &.{
                .nodes = &.{ .kinds = rows.items(.kind), .allowed = rows.items(.allowed) },
                .arguments = rows.items(.argument),
                .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
            },
            .assignments = &.{ .left = left, .right = right },
            .write = &.{ .left = @ptrCast(&left), .right = @ptrCast(&right), .count = left.len },
            .parents = @ptrCast(&parents),
            .lower = &.{ .values = depths, .output = @ptrCast(&depths) },
        },
        .resolved_indexes = graph.pending.indexes.items(.resolved),
    };

    const prepared = zx.columns.invoke(entry.executeValue, scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const solution = prepared.depth;

    if (solution.issue == .None) return .{
        .depths = depths,
        .first_deferred = @intCast(prepared.deferred.first),
        .deferred_words = @intCast(prepared.deferred.words),
    };

    const spans = assignments.items(.span);

    const span = if (solution.node) |node|
        rows.items(.span)[node]

    else if (spans.len == 0)
        rows.items(.span)[0]
    else
        spans[solution.position];

    return graph.reporter.fail(.type_mismatch, span, switch (solution.issue) {
        .Bounds => "incompatible optional input requirements",
        .OptionalToRequired => "optional input cannot satisfy a non-optional requirement",
        .Recursive => "inference would require a recursive optional type",
        .None => unreachable,
    });
}
