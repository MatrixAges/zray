const std = @import("std");
const zx = @import("zx");
const Self = @This();
const enabled = @import("rx_options").generated_graph;

pub const Window = struct { first: usize, end: usize };
pub const Batch = struct { consumed: usize, participants: usize };

batch: usize = 0,
first: usize = 0,
end: usize = 0,

pub fn window(self: *Self, batch_ends: []const usize, position: usize) ?Window {
    if (self.first != position) return null;

    if (comptime enabled and @bitSizeOf(usize) == 64 and @alignOf(u64) >= @alignOf(usize)) {
        const rule = @import("generated_rx_mixed_window");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(rule.Input) = .{
            .batch_ends = @ptrCast(batch_ends),
            .batch = self.batch,
            .first = self.first,
            .end = self.end,
        };

        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        self.batch = @intCast(result.batch);
        self.end = @intCast(result.end);
    } else if (self.first == self.end) {
        self.end = batch_ends[self.batch];
        self.batch += 1;
    }

    return .{ .first = self.first, .end = self.end };
}

pub fn prepared(self: *Self, consumed: usize) void {
    std.debug.assert(consumed != 0 and consumed <= self.end - self.first);

    self.first += consumed;
}

pub fn preparedBatch(window_range: Window, positions: []const u64, workers: usize, limit: usize, minimum: usize) Batch {
    if (comptime enabled) {
        const rule = @import("generated_rx_mixed_prepared");

        const input: std.meta.Child(rule.Input) = .{
            .positions = positions,
            .first = window_range.first,
            .end = window_range.end,
            .workers = workers,
            .limit = limit,
            .minimum = minimum,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{ .consumed = @intCast(result.consumed), .participants = @intCast(result.participants) };
    }

    const end = if (positions.len == limit) @as(usize, @intCast(positions[positions.len - 1])) + 1 else window_range.end;

    return .{
        .consumed = end - window_range.first,
        .participants = if (positions.len < minimum) 0 else @min(workers, positions.len),
    };
}

pub fn claim(positions: []const u64, cursor: *usize, position: usize) ?usize {
    if (cursor.* == positions.len) return null;

    if (comptime enabled) {
        const rule = @import("generated_rx_mixed_claim");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: std.meta.Child(rule.Input) = .{ .positions = positions, .cursor = cursor.*, .position = position };
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        cursor.* = @intCast(result.cursor);

        return if (result.row) |row| @intCast(row) else null;
    }

    while (cursor.* < positions.len and positions[cursor.*] < position) cursor.* += 1;

    if (cursor.* == positions.len or positions[cursor.*] != position) return null;

    const row = cursor.*;

    cursor.* += 1;

    return row;
}
