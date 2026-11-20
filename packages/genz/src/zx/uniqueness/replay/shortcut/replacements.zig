const std = @import("std");
const zx = @import("zx");
const Row = @import("../shortcut.zig").Replacement;
const appending = @import("generated_uniqueness_shortcut_append");
const Self = @This();

buffer: zx.memory.RowBuffer = .empty(Row),
used: usize = 0,
pub fn append(self: *Self, allocator: std.mem.Allocator, row: Row) std.mem.Allocator.Error!void {
    const input: std.meta.Child(appending.Input) = .{
        .rows = @ptrCast(&self.buffer),
        .available = self.buffer.bytes.len / @sizeOf(Row),
        .granule = @max(1, std.atomic.cache_line / @sizeOf(Row)),
        .used = self.used,
        .value = std.mem.asBytes(&row),
    };

    const used = zx.columns.invoke(appending.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    self.used = @intCast(used);
}

pub fn rows(self: *const Self) []const Row {
    return self.buffer.rows(Row)[0..self.used];
}
