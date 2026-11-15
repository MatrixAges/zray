const std = @import("std");
const zx = @import("zx");
const Body = @import("../body.zig");
const State = @import("../state.zig");
const Schedule = @import("../schedule.zig");
const generated = @import("rx_options").generated_graph and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64);

pub const Result = struct {
    position: usize,
    index: usize,
    action: Body.Action,
    prepared_row: ?usize = null,
};

pub fn next(state: *const State, first: usize, end: usize, keep_skipped: bool, positions: []const u64, cursor: *usize) Result {
    const graph = &state.graph;

    if (comptime generated) {
        const entry = @import("generated_rx_mixed_dispatch");

        const input: std.meta.Child(entry.Input) = .{
            .rows = &.{
                .order = @ptrCast(graph.order),
                .signatures = state.signature_indices,
                .sources = &.{ .zx_count = graph.sources.zx_count, .rx_end = graph.sources.rx_end },
            },
            .first = first,
            .end = end,
            .keep_skipped = keep_skipped,
            .prepared_positions = positions,
            .prepared_cursor = cursor.*,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const selected = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        cursor.* = @intCast(selected.prepared_next);

        return .{
            .position = @intCast(selected.position),
            .index = @intCast(selected.index),
            .action = @fromBackingInt(@backingInt(selected.action)),
            .prepared_row = if (selected.prepared_row) |row| @intCast(row) else null,
        };
    }

    const index = graph.order[first];
    const action = Body.admit(state, index);

    const prepared = switch (action) {
        .AnalyzeZX, .LowerRX => Schedule.claim(positions, cursor, first),
        else => null,
    };

    return .{ .position = first, .index = index, .action = action, .prepared_row = prepared };
}
