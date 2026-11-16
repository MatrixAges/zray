const Self = @This();
const Function = @import("../function_import.zig");
const Signature = @import("../source_signature.zig").Member;

default: ?*const Function = null,
named: []const Function,
pub fn names(self: Self) Names {
    return .{
        .default = if (self.default) |member| member.name else null,
        .named = .{ .functions = self.named },
    };
}

pub const Names = struct {
    default: ?[]const u8 = null,
    named: union(enum) {
        functions: []const Function,
        signatures: []const Signature,
    } = .{ .functions = &.{} },
    pub fn count(self: Names) usize {
        return @as(usize, @intFromBool(self.default != null)) + switch (self.named) {
            inline else => |items| items.len,
        };
    }

    pub fn at(self: Names, row: usize) []const u8 {
        if (row == 0) if (self.default) |name| return name;

        const index = row - @intFromBool(self.default != null);

        return switch (self.named) {
            inline else => |items| items[index].name,
        };
    }

    pub fn column(self: Names) @import("zx").memory.TextColumn {
        const memory = @import("zx").memory;

        return switch (self.named) {
            inline else => |items| memory.borrowTextColumn("name", items),
        };
    }
};

pub fn at(self: Self, row: usize) *const Function {
    if (self.default) |member| return if (row == 0) member else &self.named[row - 1];

    return &self.named[row];
}
