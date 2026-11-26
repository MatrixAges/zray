const std = @import("std");
const zx = @import("zx");
const Self = @This();

buffer: zx.memory.ByteWriter,
state_end: u64 = 0,
pub fn init(backing: std.mem.Allocator) Self {
    return .{ .buffer = .{ .allocator = backing } };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
}

pub fn binding(self: *Self, comptime State: type) State {
    return .{ .buffer = @ptrCast(&self.buffer), .state_end = self.state_end };
}

pub fn stateEnd(self: *const Self) usize {
    return @intCast(self.state_end);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.buffer.buffer.items;
}
