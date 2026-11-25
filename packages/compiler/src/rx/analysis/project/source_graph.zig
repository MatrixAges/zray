const std = @import("std");
const zx = @import("zx");
const model = @import("source_graph/model.zig");
pub const Result = model.Result;
pub const Graph = model.Graph;
pub const Reference = model.Reference;
pub const Signatures = @import("references/signatures.zig");
pub const references = @import("source_graph/rx_edges.zig");
pub const Options = model.Options;

pub fn build(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Result {
    return buildWithRoots(allocator, options, options.additional_roots);
}

/// Explicit roots may be path slices or the project's original export records.
pub fn buildWithRoots(allocator: std.mem.Allocator, options: Options, roots: anytype) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const value = try @import("source_graph/construct.zig").build(arena.allocator(), options.scratch_allocator orelse allocator, options, roots);

    return .{ .arena = arena, .value = value };
}

pub fn orderedRows(allocator: std.mem.Allocator, graph: *const Graph, kind: enum { zx, rx }) std.mem.Allocator.Error![]const u64 {
    const first = if (kind == .zx) 0 else graph.sources.zx_count;
    const end = if (kind == .zx) graph.sources.zx_count else graph.sources.rx_end;
    var entries = try allocator.alloc(u64, @min(end - first, graph.order.len));

    if (entries.len == 0) return entries;

    errdefer allocator.free(entries);

    if (comptime @import("rx_options").generated_graph and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64)) {
        const rule = @import("generated_source_graph_ordered_rows");

        const input: std.meta.Child(rule.Input) = .{
            .order = @ptrCast(graph.order),
            .first = first,
            .end = end,
            .entries = @ptrCast(&entries),
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const count = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return allocator.realloc(entries, @intCast(count));
    }

    var count: usize = 0;

    for (graph.order) |row| {
        if (row < first or row >= end) continue;

        entries[count] = row - first;
        count += 1;
    }

    return allocator.realloc(entries, count);
}
