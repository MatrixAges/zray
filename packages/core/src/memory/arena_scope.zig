const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Arena = std.heap.ArenaAllocator;
const Self = @This();

active: Allocator,
pub fn allocator(self: *Self) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
}

pub fn select(source: *anyopaque, arena: *anyopaque) void {
    // After switching arenas, allocations from the preceding phase are read-only.
    const next: *Arena = @ptrCast(@alignCast(arena));
    const self: *Self = @ptrCast(@alignCast(source));

    self.active = next.allocator();
}

pub fn selectAllocator(source: *anyopaque, resource: *const anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(source));
    const next: *const Allocator = @ptrCast(@alignCast(resource));
    self.active = next.*;
}

fn target(context: *anyopaque) Allocator {
    const self: *const Self = @ptrCast(@alignCast(context));

    return self.active;
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
