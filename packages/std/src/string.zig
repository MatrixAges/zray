const std = @import("std");

pub fn join(allocator: std.mem.Allocator, separator: []const u8, values: []const []const u8) std.mem.Allocator.Error![]const u8 {
    return std.mem.join(allocator, separator, values);
}

pub fn copy(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, value);
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
