const std = @import("std");
const rx = @import("rx");
const Columns = @import("../layout.zig").Columns;
const target = @import("../../call/target.zig");

pub fn plan(allocator: std.mem.Allocator, fragments: []const rx.ast.Node, offsets: []const u64, fields: []*const rx.ast.Node) std.mem.Allocator.Error!Columns {
    const expressions = try allocator.alloc([]const u8, fields.len);

    for (fragments, offsets[0..fragments.len]) |fragment, offset| {
        for (fragment.children, @as(usize, @intCast(offset))..) |*field, index| {
            fields[index] = field;
            expressions[index] = target.attribute(field.*, "type").value;
        }
    }

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

    return .{ .expressions = expressions, .names = names, .ends = ends, .text = text.items };
}
