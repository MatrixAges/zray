const std = @import("std");
const memory = @import("zx").memory;
const Slot = @import("root.zig").Slot;
const Self = @This();

indices: memory.ReadColumn,
writable: memory.ReadColumn,
pub fn columns(indices: []const u64, writable: []const bool) Self {
    return .{ .indices = dense(u64, indices), .writable = dense(bool, writable) };
}

pub fn rows(values: []const Slot) Self {
    return .{
        .indices = memory.borrowReadColumn(u64, "index", values),
        .writable = memory.borrowReadColumn(bool, "writable", values),
    };
}

pub fn bind(self: *const Self, comptime Range: type) Range {
    return .{
        .indices = @ptrCast(&self.indices),
        .writable = @ptrCast(&self.writable),
        .first = 0,
        .count = self.indices.count,
    };
}

fn dense(comptime T: type, values: []const T) memory.ReadColumn {
    return .{ .bytes = std.mem.sliceAsBytes(values), .count = values.len, .stride = @sizeOf(T), .offset = 0 };
}
