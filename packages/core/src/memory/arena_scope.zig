const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Arena = std.heap.ArenaAllocator;
const Self = @This();

active: *Arena,
pub fn allocator(self: *Self) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
}

pub fn select(source: *const anyopaque, arena: *const anyopaque) void {
    // After switching arenas, allocations from the preceding phase are read-only.
    const self: *Self = @ptrCast(@alignCast(@constCast(source)));

    self.active = @ptrCast(@alignCast(@constCast(arena)));
}

fn target(context: *anyopaque) Allocator {
    const self: *const Self = @ptrCast(@alignCast(context));

    return self.active.allocator();
}

fn allocate(context: *anyopaque, size: usize, alignment: Alignment, address: usize) ?[*]u8 {
    return target(context).rawAlloc(size, alignment, address);
}

fn resize(context: *anyopaque, bytes: []u8, alignment: Alignment, size: usize, address: usize) bool {
    return target(context).rawResize(bytes, alignment, size, address);
}

fn remap(context: *anyopaque, bytes: []u8, alignment: Alignment, size: usize, address: usize) ?[*]u8 {
    return target(context).rawRemap(bytes, alignment, size, address);
}

fn free(context: *anyopaque, bytes: []u8, alignment: Alignment, address: usize) void {
    target(context).rawFree(bytes, alignment, address);
}
