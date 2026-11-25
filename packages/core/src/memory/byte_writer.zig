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

pub fn length(target: *const anyopaque) u64 {
    return borrowConst(target).buffer.items.len;
}

pub fn borrowBytes(target: *const anyopaque) []const u8 {
    return borrowConst(target).buffer.items;
}

pub fn clear(target: *anyopaque) void {
    borrow(target).buffer.clearRetainingCapacity();
}

pub fn reverseTail(target: *anyopaque, start: u64) void {
    std.mem.reverse(u8, borrow(target).buffer.items[@intCast(start)..]);
}

inline fn borrow(target: *anyopaque) *Self {
    return @ptrCast(@alignCast(target));
}

inline fn borrowConst(target: *const anyopaque) *const Self {
    return @ptrCast(@alignCast(target));
}
