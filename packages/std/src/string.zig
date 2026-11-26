const std = @import("std");

pub fn join(allocator: std.mem.Allocator, separator: []const u8, values: []const []const u8) std.mem.Allocator.Error![]const u8 {
    return std.mem.join(allocator, separator, values);
}

pub fn copy(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, value);
}

pub inline fn sameStorage(left: []const u8, right: []const u8) bool {
    return left.ptr == right.ptr and left.len == right.len;
}

/// Replaces a non-empty literal pattern. With no match, the result borrows the input.
pub fn replaceAll(allocator: std.mem.Allocator, value: []const u8, pattern: []const u8, replacement: []const u8) (std.mem.Allocator.Error || error{EmptyPattern})![]const u8 {
    if (pattern.len == 0) return error.EmptyPattern;
    if (std.mem.indexOf(u8, value, pattern) == null) return value;

    return std.mem.replaceOwned(u8, allocator, value, pattern, replacement);
}

pub fn copyList(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const output = try allocator.alloc([]const u8, values.len);
    var copied: usize = 0;

    errdefer allocator.free(output);
    errdefer for (output[0..copied]) |value| allocator.free(value);

    for (values, output) |value, *item| {
        item.* = try copy(allocator, value);
        copied += 1;
    }

    return output;
}
