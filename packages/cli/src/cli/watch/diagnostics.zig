const std = @import("std");
const builtin = @import("builtin");
const rule = @import("cli_source").normalize_backend_diagnostic;

pub fn key(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);

    defer output.deinit();

    const written = try rule.executeValue(allocator, &.{
        .writer = @ptrCast(&output.writer),
        .message = message,
        .windows = builtin.os.tag == .windows,
    });

    return if (written) try output.toOwnedSlice() else message;
}
