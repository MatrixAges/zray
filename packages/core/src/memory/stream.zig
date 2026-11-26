const std = @import("std");
const Reader = std.Io.Reader;

pub fn takeByte(source: *anyopaque) Reader.Error!u8 {
    return reader(source).takeByte();
}

pub fn takeU32Le(source: *anyopaque) Reader.Error!u32 {
    return reader(source).takeInt(u32, .little);
}

pub fn takeU64Le(source: *anyopaque) Reader.Error!u64 {
    return reader(source).takeInt(u64, .little);
}

pub fn takeText(allocator: std.mem.Allocator, source: *anyopaque, count: u32) (Reader.Error || std.mem.Allocator.Error)![]const u8 {
    return reader(source).readAlloc(allocator, count);
}

fn reader(source: *anyopaque) *Reader {
    return @ptrCast(@alignCast(source));
}
