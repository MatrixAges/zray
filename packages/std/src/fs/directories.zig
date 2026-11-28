const std = @import("std");
const builtin = @import("builtin");
const darwin = @import("darwin_directory.zig");
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

    if (comptime builtin.os.tag.isDarwin()) {
        if (listMetadata(allocator, io, input, true)) |entries| return entries else |err| switch (err) {
            error.BulkDirectoryUnavailable => {},
            else => |failure| return failure,
        }
    }

    return listMetadata(allocator, io, input, false);
}

fn listMetadata(allocator: Allocator, io: std.Io, input: []const u8, comptime bulk: bool) ![]const api.DirectoryEntry {
    const directory = try std.Io.Dir.cwd().openDir(io, input, .{ .iterate = true });

    defer directory.close(io);

    var entries: std.ArrayList(api.DirectoryEntry) = .empty;

    errdefer {
        for (entries.items) |entry| {
            if (entry.mtime_ns) |modified| allocator.destroy(modified);

            if (comptime @hasField(@TypeOf(entry.*), "ctime_ns")) {
                if (entry.ctime_ns) |changed| allocator.destroy(changed);
            }

            allocator.free(entry.name);
            allocator.destroy(entry);
        }

        entries.deinit(allocator);
    }

    if (bulk) {
        var iterator: darwin.Iterator = .{ .directory = directory };

        while (try iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

            const info: EntryStat = if (entry.stat) |stat| .{
                .inode = stat.inode,
                .size = stat.size,
                .mtime = stat.mtime,
                .ctime = stat.ctime,
            } else try entryStat(io, directory, entry.name, entry.inode);

            try appendMetadata(allocator, &entries, entry.name, entry.kind, info);
        }
    } else {
        var iterator = directory.iterate();

        while (try iterator.next(io)) |entry| {
            const info = try entryStat(io, directory, entry.name, entry.inode);

            try appendMetadata(allocator, &entries, entry.name, entry.kind, info);
        }
    }

    return entries.toOwnedSlice(allocator);
}

const EntryStat = struct {
    inode: ?u64,
    size: ?u64 = null,
    mtime: ?i96 = null,
    ctime: ?i96 = null,
};

fn entryStat(io: std.Io, directory: std.Io.Dir, name: []const u8, inode: u64) !EntryStat {
    const stat = directory.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .inode = if (inode != 0) inode else null },
        else => |failure| return failure,
    };

    return .{
        .inode = stat.inode,
        .size = stat.size,
        .mtime = stat.mtime.nanoseconds,
        .ctime = stat.ctime.nanoseconds,
    };
}

fn appendMetadata(allocator: Allocator, entries: *std.ArrayList(api.DirectoryEntry), name: []const u8, kind: std.Io.File.Kind, info: EntryStat) !void {
    try entries.ensureUnusedCapacity(allocator, 1);

    const value = try allocator.create(@typeInfo(api.DirectoryEntry).pointer.child);

    errdefer allocator.destroy(value);

    const owned_name = try allocator.dupe(u8, name);

    errdefer allocator.free(owned_name);

    const modified = if (info.mtime) |ns| try timestamp(allocator, ns) else null;

    errdefer if (modified) |time| allocator.destroy(time);

    value.name = owned_name;
    value.kind = metadata.kind(kind);
    value.inode = info.inode;
    value.size = info.size;
    value.mtime_ns = modified;

    // A previously built generator may still emit the ABI without change time.
    if (comptime @hasField(@TypeOf(value.*), "ctime_ns")) {
        value.ctime_ns = if (info.ctime) |ns| try timestamp(allocator, ns) else null;
    }

    entries.appendAssumeCapacity(value);
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
