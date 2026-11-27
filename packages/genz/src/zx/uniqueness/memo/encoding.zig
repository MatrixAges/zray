const std = @import("std");
const Self = @This();

allocator: std.mem.Allocator,
buffer: std.ArrayList(u8) = .empty,
state_end: usize = 0,
pub fn init(backing: std.mem.Allocator) Self {
    return .{ .allocator = backing };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit(self.allocator);
}

pub fn capture(self: *Self, encoded: anytype) std.mem.Allocator.Error!void {
    try self.buffer.ensureTotalCapacity(self.allocator, @intCast(encoded.size));

    self.buffer.clearRetainingCapacity();

    for (encoded.chunks) |chunk| self.buffer.appendSliceAssumeCapacity(chunk);

    self.state_end = @intCast(encoded.state_end);
}

pub fn stateEnd(self: *const Self) usize {
    return self.state_end;
}

pub fn bytes(self: *const Self) []const u8 {
    return self.buffer.items;
}
