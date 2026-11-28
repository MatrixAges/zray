const std = @import("std");

pub fn validate(path: []const u8) !void {
    try validateBytes(path);
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
}

pub fn validateBytes(path: []const u8) error{InvalidPath}!void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}
