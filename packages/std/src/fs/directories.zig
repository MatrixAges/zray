const std = @import("std");
const api = @import("zxc_abi").native.@"std:fs";
const path = @import("path.zig");
const metadata = @import("metadata.zig");
const Allocator = std.mem.Allocator;

pub fn mkdir(io: std.Io, input: api.mkdir.Input) !void {
    try path.validate(input.path);

    if (input.recursive) {
        try std.Io.Dir.cwd().createDirPath(io, input.path);
    } else try std.Io.Dir.cwd().createDir(io, input.path, .default_dir);
}

pub fn readdir(allocator: Allocator, io: std.Io, input: []const u8) ![]const []const u8 {
    try path.validate(input);

    const directory = try std.Io.Dir.cwd().openDir(io, input, .{ .iterate = true });

    defer directory.close(io);

    var entries: std.ArrayList([]const u8) = .empty;

    errdefer {
        for (entries.items) |entry| allocator.free(entry);

        entries.deinit(allocator);
    }

    var iterator = directory.iterate();

    while (try iterator.next(io)) |entry| {
        if (!std.unicode.utf8ValidateSlice(entry.name)) return error.InvalidUtf8;
        try entries.ensureUnusedCapacity(allocator, 1);

        entries.appendAssumeCapacity(try allocator.dupe(u8, entry.name));
    }

    return entries.toOwnedSlice(allocator);
}

pub fn readdirMetadata(allocator: Allocator, io: std.Io, input: []const u8) ![]const api.DirectoryEntry {
    try path.validateBytes(input);

    const directory = try std.Io.Dir.cwd().openDir(io, input, .{ .iterate = true });

    defer directory.close(io);

    var entries: std.ArrayList(api.DirectoryEntry) = .empty;

    errdefer {
        for (entries.items) |entry| {
            if (entry.mtime_ns) |modified| allocator.destroy(modified);

            allocator.free(entry.name);
            allocator.destroy(entry);
        }

        entries.deinit(allocator);
    }

    var iterator = directory.iterate();

    while (try iterator.next(io)) |entry| {
        const info: ?std.Io.File.Stat = directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |failure| return failure,
        };

        try entries.ensureUnusedCapacity(allocator, 1);

        const value = try allocator.create(@typeInfo(api.DirectoryEntry).pointer.child);

        errdefer allocator.destroy(value);

        const name = try allocator.dupe(u8, entry.name);

        errdefer allocator.free(name);

        value.* = .{
            .name = name,
            .kind = metadata.kind(entry.kind),
            .inode = if (info) |stat| stat.inode else if (entry.inode != 0) entry.inode else null,
            .size = if (info) |stat| stat.size else null,
            .mtime_ns = if (info) |stat| try timestamp(allocator, stat.mtime.nanoseconds) else null,
        };

        entries.appendAssumeCapacity(value);
    }

    return entries.toOwnedSlice(allocator);
}

fn timestamp(allocator: Allocator, nanoseconds: i96) !api.TimestampNs {
    const value = try allocator.create(@typeInfo(api.TimestampNs).pointer.child);

    value.* = .{
        .high = @intCast(nanoseconds >> 64),
        .low = @truncate(@as(u96, @bitCast(nanoseconds))),
    };

    return value;
}

pub fn rmdir(io: std.Io, input: []const u8) !void {
    try path.validate(input);
    try std.Io.Dir.cwd().deleteDir(io, input);
}
