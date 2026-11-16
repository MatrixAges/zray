const std = @import("std");
const Error = std.mem.Allocator.Error || error{IndexOutOfBounds};

pub fn readU8s(allocator: std.mem.Allocator, source: []const u8, start: u64, end: u64) Error![]const u8 {
    return read(u8, allocator, source, start, end);
}

pub fn readU32sLe(allocator: std.mem.Allocator, source: []const u8, start: u64, end: u64) Error![]const u32 {
    return read(u32, allocator, source, start, end);
}

pub fn readU64sLe(allocator: std.mem.Allocator, source: []const u8, start: u64, end: u64) Error![]const u64 {
    return read(u64, allocator, source, start, end);
}

fn read(comptime T: type, allocator: std.mem.Allocator, source: []const u8, start: u64, end: u64) Error![]const T {
    if (start > end or end > source.len or (end - start) % @sizeOf(T) != 0) return error.IndexOutOfBounds;

    const raw = source[@intCast(start)..@intCast(end)];
    const output = try allocator.alloc(T, raw.len / @sizeOf(T));

    @memcpy(std.mem.sliceAsBytes(output), raw);

    if (@sizeOf(T) != 1 and @import("builtin").target.cpu.arch.endian() != .little) {
        for (output) |*value| value.* = @byteSwap(value.*);
    }

    return output;
}
