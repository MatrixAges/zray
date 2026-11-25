const std = @import("std");
const Error = std.mem.Allocator.Error;

/// Borrows the host's fixed or allocating writer for one synchronous encoding call.
fn writer(out: *anyopaque) *std.Io.Writer {
    return @ptrCast(@alignCast(out));
}

pub fn write(out: *anyopaque, value: []const u8) Error!void {
    writer(out).writeAll(value) catch return error.OutOfMemory;
}

pub fn writeMasked(out: *anyopaque, value: []const u8, mask: u8) Error!void {
    const target = writer(out).writableSlice(value.len) catch return error.OutOfMemory;

    for (target, value) |*byte, source| byte.* = source & mask;
}

pub fn writeByte(out: *anyopaque, value: u8) Error!void {
    writer(out).writeByte(value) catch return error.OutOfMemory;
}

pub fn writeU32Le(out: *anyopaque, value: u32) Error!void {
    writer(out).writeInt(u32, value, .little) catch return error.OutOfMemory;
}

pub fn writeU64Le(out: *anyopaque, value: u64) Error!void {
    writer(out).writeInt(u64, value, .little) catch return error.OutOfMemory;
}

/// Writes the full width of a u64 as 16 lowercase hexadecimal digits.
pub fn writeHexU64(out: *anyopaque, value: u64) Error!void {
    writer(out).print("{x:0>16}", .{value}) catch return error.OutOfMemory;
}

pub fn writeDecimalU64(out: *anyopaque, value: u64) Error!void {
    writer(out).print("{d}", .{value}) catch return error.OutOfMemory;
}

pub fn writeU32sLe(out: *anyopaque, values: []const u32) Error!void {
    writer(out).writeSliceEndian(u32, values, .little) catch return error.OutOfMemory;
}

pub fn writeU64sLe(out: *anyopaque, values: []const u64) Error!void {
    writer(out).writeSliceEndian(u64, values, .little) catch return error.OutOfMemory;
}
