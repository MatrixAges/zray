const std = @import("std");
const borrowAllocator = @import("column_set.zig").borrowAllocator;
const Text = []const u8;

pub fn allocate(comptime T: type, resource: *const anyopaque, count: u64) ?[]const T {
    const length = std.math.cast(usize, count) orelse return null;

    return borrowAllocator(resource).alloc(T, length) catch null;
}

pub fn write(comptime T: type, target: []const T, index: u64, value: T) void {
    @constCast(target)[@intCast(index)] = value;
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
