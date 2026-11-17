const std = @import("std");

pub fn strings(allocator: std.mem.Allocator, source: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, source.len);

    for (source, result) |text, *owned| owned.* = try allocator.dupe(u8, text);

    return result;
}
