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

pub inline fn u32s(resource: *const anyopaque, count: u64, shape: anytype) Allocator.Error!std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(try create(u32, resource, count));
}

fn create(comptime Item: type, resource: *const anyopaque, count: u64) Allocator.Error!*[]Item {
    comptime std.debug.assert(@alignOf([]Item) >= @alignOf(Item));

    const allocator = @import("column_set.zig").borrowAllocator(resource);
    const offset = @sizeOf([]Item);
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const payload = std.math.mul(usize, length, @sizeOf(Item)) catch return error.OutOfMemory;
    const size = std.math.add(usize, offset, payload) catch return error.OutOfMemory;
    const storage = try allocator.alignedAlloc(u8, .of([]Item), size);
    const buffer: *[]Item = @ptrCast(storage.ptr);
    const items: [*]Item = @ptrCast(@alignCast(storage.ptr + offset));
    buffer.* = items[0..length];

    return buffer;
}
