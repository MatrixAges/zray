const std = @import("std");
pub const U64U32Map = std.AutoHashMapUnmanaged(u64, u32);

fn map(handle: *const anyopaque) *U64U32Map {
    const pointer: *const *U64U32Map = @ptrCast(@alignCast(handle));

    return pointer.*;
}

pub fn findU64U32Entry(handle: *const anyopaque, key: u64) ?u32 {
    return map(handle).get(key);
}

pub fn readU64U32Entry(handle: *const anyopaque, key: u64) u32 {
    return map(handle).get(key).?;
}

pub fn writeU64U32Entry(allocator: std.mem.Allocator, handle: *const anyopaque, key: u64, value: u32) error{OutOfMemory}!void {
    try map(handle).put(allocator, key, value);
}
