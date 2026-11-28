const std = @import("std");

pub fn relativePathFrom(allocator: std.mem.Allocator, base: []const u8, target: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fs.path.relativeAlloc(allocator, base, null, base, target);
}
