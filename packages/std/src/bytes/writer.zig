const std = @import("std");
const Error = std.mem.Allocator.Error;

/// Borrows the host's fixed or allocating writer for one synchronous encoding call.
fn writer(out: *anyopaque) *std.Io.Writer {
    return @ptrCast(@alignCast(out));
}

pub fn write(out: *anyopaque, value: []const u8) Error!void {
    writer(out).writeAll(value) catch return error.OutOfMemory;
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
