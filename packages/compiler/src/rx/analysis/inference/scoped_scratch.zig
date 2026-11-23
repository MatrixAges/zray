const std = @import("std");
const zx = @import("zx");

pub fn Buffer(comptime size: usize) type {
    return struct {
        const Self = @This();

        bytes: [size]u8 = undefined,
        arena: std.heap.ArenaAllocator = undefined,
        front: std.heap.BufferFirstAllocator = undefined,
        previous: ?std.mem.Allocator = null,
        pub fn open(self: *Self, scope: *zx.memory.ArenaScope, allocator: std.mem.Allocator) std.mem.Allocator {
            self.arena = .init(allocator);
            self.front = .init(&self.bytes, self.arena.allocator());
            self.previous = scope.active;
            scope.active = self.front.allocator();

            return scope.active;
        }

        pub fn close(self: *Self, scope: *zx.memory.ArenaScope) void {
            const previous = self.previous orelse return;

            scope.active = previous;
            self.previous = null;

            self.arena.deinit();
        }
    };
}
