const std = @import("std");
const Allocator = std.mem.Allocator;

pub inline fn bytes(resource: *const anyopaque, count: u64, shape: anytype) Allocator.Error!std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(try create(u8, resource, count));
}

pub inline fn bools(resource: *const anyopaque, count: u64, shape: anytype) Allocator.Error!std.meta.Child(@TypeOf(shape)) {
    const buffer = try create(bool, resource, count);

    @memset(buffer.*, false);

    return @ptrCast(buffer);
}

fn create(comptime Item: type, resource: *const anyopaque, count: u64) Allocator.Error!*[]Item {
    const allocator = @import("column_set.zig").borrowAllocator(resource);
    const offset = @sizeOf([]Item);
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const size = std.math.add(usize, offset, length) catch return error.OutOfMemory;
    const storage = try allocator.alignedAlloc(u8, .of([]Item), size);
    const buffer: *[]Item = @ptrCast(storage.ptr);
    const items: [*]Item = @ptrCast(storage.ptr + offset);

    comptime std.debug.assert(@sizeOf(Item) == 1 and @alignOf(Item) == 1);

    buffer.* = items[0..length];

    return buffer;
}
