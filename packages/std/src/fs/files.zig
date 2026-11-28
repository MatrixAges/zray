const std = @import("std");
const api = @import("zxc_abi").native.@"std:fs";
const path = @import("path.zig");
const Allocator = std.mem.Allocator;

pub fn readFile(allocator: Allocator, io: std.Io, input: anytype) ![]const u8 {
    try path.validate(input.path);

    const max_bytes: u64 = input.max_bytes;

    return std.Io.Dir.cwd().readFileAlloc(io, input.path, allocator, .limited64(max_bytes +| 1));
}

pub fn readFilePrefix(allocator: Allocator, io: std.Io, input: api.readFilePrefix.Input) !?[]const u8 {
    try path.validate(input.path);

    const file = std.Io.Dir.cwd().openFile(io, input.path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |failure| return failure,
    };

    defer file.close(io);

    const limit = std.math.cast(usize, input.max_bytes) orelse return error.FileTooBig;
    var reader = file.reader(io, &.{});
    const bytes = try allocator.alloc(u8, limit);

    errdefer allocator.free(bytes);

    const length = reader.interface.readSliceShort(bytes) catch return reader.err.?;

    return try allocator.realloc(bytes, length);
}

pub fn readFileOptional(allocator: Allocator, io: std.Io, input: []const u8) !?[]const u8 {
    try path.validate(input);

    return std.Io.Dir.cwd().readFileAlloc(io, input, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |failure| return failure,
    };
}

pub fn readText(allocator: Allocator, io: std.Io, input: api.readText.Input) ![]const u8 {
    const bytes = try readFile(allocator, io, input);

    errdefer allocator.free(bytes);

    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;

    return bytes;
}

pub fn writeFile(io: std.Io, input: api.writeFile.Input) !void {
    try path.validate(input.path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input.path, .data = input.data });
}

pub fn writeFileAtomic(io: std.Io, input: anytype) !void {
    if (std.mem.indexOfScalar(u8, input.path, 0) != null) return error.InvalidPath;

    var file = try std.Io.Dir.cwd().createFileAtomic(io, input.path, .{ .make_path = input.make_path, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, input.data);
    try file.replace(io);
}

pub fn writeText(io: std.Io, input: api.writeText.Input) !void {
    try path.validate(input.path);
    if (!std.unicode.utf8ValidateSlice(input.text)) return error.InvalidUtf8;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input.path, .data = input.text });
}

pub fn truncate(io: std.Io, input: api.truncate.Input) !void {
    try path.validate(input.path);

    const file = try std.Io.Dir.cwd().openFile(io, input.path, .{ .mode = .write_only, .allow_directory = false });

    defer file.close(io);

    try file.setLength(io, input.length);
}
