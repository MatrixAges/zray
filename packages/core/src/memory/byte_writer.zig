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

pub fn appendByte(target: *const anyopaque, byte: u8) std.mem.Allocator.Error!void {
    const self = borrow(target);

    try self.buffer.append(self.allocator, byte);
}

pub fn appendBytes(target: *const anyopaque, bytes: []const u8) std.mem.Allocator.Error!void {
    const self = borrow(target);

    try self.buffer.appendSlice(self.allocator, bytes);
}

pub fn length(target: *const anyopaque) u64 {
    return borrow(target).buffer.items.len;
}

pub fn reverseTail(target: *const anyopaque, start: u64) void {
    std.mem.reverse(u8, borrow(target).buffer.items[@intCast(start)..]);
}

inline fn borrow(target: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(target)));
}
