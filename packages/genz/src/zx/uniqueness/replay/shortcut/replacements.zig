const std = @import("std");
const Row = @import("../shortcut.zig").Replacement;
const Self = @This();

items: std.ArrayList(Row) = .empty,
pub fn rows(self: *const Self) []const Row {
    return self.items.items;
}
