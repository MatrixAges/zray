const std = @import("std");
const Self = @This();

allocator: std.mem.Allocator,
buffer: std.ArrayList(u8) = .empty,
pub fn deinit(self: *Self) void {
    self.buffer.deinit(self.allocator);
}

pub fn finish(self: *Self) std.mem.Allocator.Error![]u8 {
    return self.buffer.toOwnedSlice(self.allocator);
}

pub fn appendByte(target: *anyopaque, byte: u8) std.mem.Allocator.Error!void {
    const self = borrow(target);

    try self.buffer.append(self.allocator, byte);
}

pub fn appendBytes(target: *anyopaque, bytes: []const u8) std.mem.Allocator.Error!void {
    const self = borrow(target);

    try self.buffer.appendSlice(self.allocator, bytes);
}

inline fn borrow(target: *anyopaque) *Self {
    return @ptrCast(@alignCast(target));
}
