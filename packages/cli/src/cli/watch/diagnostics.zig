const std = @import("std");
const builtin = @import("builtin");
const rule = @import("cli_source").normalize_backend_diagnostic;

pub fn key(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const normalized = try rule.executeIn(allocator, &.{
        .message = message,
        .windows = builtin.os.tag == .windows,
    });

    return normalized orelse message;
}
