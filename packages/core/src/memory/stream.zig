const std = @import("std");
const Reader = std.Io.Reader;

pub fn takeByte(source: *const anyopaque) Reader.Error!u8 {
    return reader(source).takeByte();
}

pub fn takeU32Le(source: *const anyopaque) Reader.Error!u32 {
    return reader(source).takeInt(u32, .little);
}

pub fn takeU64Le(source: *const anyopaque) Reader.Error!u64 {
    return reader(source).takeInt(u64, .little);
}

pub fn takeText(allocator: std.mem.Allocator, source: *const anyopaque, count: u32) (Reader.Error || std.mem.Allocator.Error)![]const u8 {
    return reader(source).readAlloc(allocator, count);
}

fn reader(source: *const anyopaque) *Reader {
    return @ptrCast(@alignCast(@constCast(source)));
}
