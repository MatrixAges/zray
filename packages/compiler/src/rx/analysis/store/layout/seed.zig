const std = @import("std");
const Columns = @import("../layout.zig").Columns;

pub fn plan(allocator: std.mem.Allocator, expressions: []const []const u8) std.mem.Allocator.Error!Columns {
    const names = try allocator.alloc([]const u8, expressions.len);
    const ends = try allocator.alloc(u64, expressions.len);
    var text: std.ArrayList(u8) = .empty;

    for (expressions, names, ends, 0..) |expression, *name, *end, index| {
        name.* = try std.fmt.allocPrint(allocator, "StoreValue{d}", .{index});

        try text.appendSlice(allocator, "export type ");
        try text.appendSlice(allocator, name.*);
        try text.appendSlice(allocator, " = ");
        try text.appendSlice(allocator, expression);
        try text.append(allocator, '\n');

        end.* = text.items.len;
    }

    return .{ .names = names, .ends = ends, .text = text.items };
}
