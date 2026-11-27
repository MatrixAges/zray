const std = @import("std");

pub fn strings(allocator: std.mem.Allocator, source: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    var written: usize = 0;

    errdefer allocator.free(result);
    errdefer for (result[0..written]) |text| allocator.free(text);

    for (source, result) |text, *owned| {
        owned.* = try allocator.dupe(u8, text);
        written += 1;
    }

    return result;
}
