const std = @import("std");
const Graph = @import("../types.zig");
const enabled = @import("rx_options").generated_graph;
pub const query = if (enabled) @import("generated_object_closure_query") else void;
pub const QueryInput = if (enabled) std.meta.Child(query.Input) else void;
pub const QuerySnapshot = if (enabled) std.meta.Child(std.meta.Child(@FieldType(QueryInput, "snapshot"))) else void;

pub const Snapshot = struct {
    query: QuerySnapshot,
    known: []const bool,
    sizes: []const u64,
    results: []const u64,
    offsets: []const u64,
    dependents: []const u64,
};

pub fn build(graph: *const Graph, allocator: std.mem.Allocator) std.mem.Allocator.Error!Snapshot {
    const layout = @import("generated_object_closure_layout");
    const rows = graph.nodes.slice();
    const constructions = graph.pending.constructions.slice();
    const parts = graph.pending.construction_parts.slice();
    const selections = graph.pending.selections.slice();
    const parents = graph.parents();

    const input: std.meta.Child(layout.Input) = .{
        .kinds = rows.items(.kind),
        .columns = &.{
            .construction_results = @ptrCast(constructions.items(.result)),
            .part_first = constructions.items(.first),
            .part_count = constructions.items(.count),
            .part_names = parts.items(.name),
            .part_values = @ptrCast(parts.items(.value)),
            .selection_results = @ptrCast(selections.items(.result)),
            .selection_sources = @ptrCast(selections.items(.source)),
        },
        .parents = @ptrCast(&parents),
    };

    const result = layout.executeValue(allocator, &input) catch |err| return failure(err);

    return .{
        .query = .{
            .revision = graph.object_revision,
            .keys = result.keys,
            .buckets = result.buckets,
            .spread = null,
            .selection = null,
        },
        .known = result.known,
        .sizes = result.sizes,
        .results = result.results,
        .offsets = result.offsets,
        .dependents = result.dependents,
    };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
