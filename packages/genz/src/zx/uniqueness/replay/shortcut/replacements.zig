const zx = @import("zx");
const Row = @import("../shortcut.zig").Replacement;
const Self = @This();

buffer: zx.memory.RowBuffer = .empty(Row),
used: usize = 0,
pub fn rows(self: *const Self) []const Row {
    return self.buffer.rows(Row)[0..self.used];
}
