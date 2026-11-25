const std = @import("std");
const borrowAllocator = @import("column_set.zig").borrowAllocator;
const Text = []const u8;

pub fn allocate(comptime T: type, resource: *const anyopaque, count: u64, shape: anytype) ?std.meta.Child(@TypeOf(shape)) {
    const length = std.math.cast(usize, count) orelse return null;
    const items = borrowAllocator(resource).alloc(T, length) catch return null;

    return @ptrCast(items.ptr);
}

pub fn write(comptime T: type, target: *anyopaque, index: u64, value: T) void {
    const items: [*]T = @ptrCast(@alignCast(target));

    items[@intCast(index)] = value;
}

pub fn read(comptime T: type, source: *const anyopaque, index: u64) T {
    const items: [*]const T = @ptrCast(@alignCast(source));

    return items[@intCast(index)];
}

pub fn borrow(comptime T: type, source: *const anyopaque, count: u64) []const T {
    const items: [*]const T = @ptrCast(@alignCast(source));

    return items[0..@intCast(count)];
}

pub fn duplicate(resource: *const anyopaque, source: Text) ?Text {
    return borrowAllocator(resource).dupe(u8, source) catch null;
}

pub fn free(resource: *const anyopaque, items: anytype) void {
    borrowAllocator(resource).free(items);
}

pub fn require(value: anytype) std.mem.Allocator.Error!std.meta.Child(@TypeOf(value)) {
    return value orelse error.OutOfMemory;
}

pub fn checkLength(expected: u64, length: u64) error{IndexOutOfBounds}!void {
    if (expected != length) return error.IndexOutOfBounds;
}
