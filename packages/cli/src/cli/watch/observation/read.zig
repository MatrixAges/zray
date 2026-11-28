const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const versions = @import("compiler").input_snapshot;
const storage = @import("storage.zig");
const rule = @import("cli_source").read;

pub fn observe(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory_entries: bool) !Snapshot.State {
    const reading = try rule.executeIn(allocator, &.{
        .path = path,
        .directory_entries = directory_entries,
        .started = null,
    }, io);

    const fact = reading.fact;

    return switch (fact.kind) {
        .Missing => .missing,
        .Failed => return failure(fact.tag),
        .Other => .{ .other = @fromBackingInt(@intCast(fact.tag)) },
        .File => .{ .file = content(fact) },
        .Directory => .{ .directory = content(fact) },
    };
}

fn content(fact: *const storage.Fact) Snapshot.Content {
    return .{ .digest = fact.digest[0..32].*, .physical_path = fact.physical_path };
}

pub fn failure(tag: u32) anyerror {
    const ErrorNumber = @TypeOf(@intFromError(error.OutOfMemory));

    return @errorFromInt(@as(ErrorNumber, @intCast(tag)));
}

pub fn classify(allocator: std.mem.Allocator, io: std.Io, path: []const u8, previous: ?*const storage.VersionRequest) !*const storage.Classification {
    const info = try allocator.create(storage.Classification);
    info.* = .{ .kind = .Missing, .tag = 0, .unchanged = false, .failure = null };

    const stat = (statPath(io, path) catch |err| {
        info.failure = @intFromError(err);

        return info;
    }) orelse return info;

    switch (stat.kind) {
        .file => {
            info.kind = .File;

            if (previous) |request| {
                const verified = versionFromFields(request.previous);

                info.unchanged = verified.matchesStat(io, path, request.physical_path, stat) catch |err| matched: {
                    info.failure = @intFromError(err);

                    break :matched false;
                };
            }
        },
        .directory => info.kind = .Directory,
        else => |kind| {
            info.kind = .Other;
            info.tag = @backingInt(kind);
        },
    }

    return info;
}

const ReadResult = struct {
    fact: storage.Fact,
    reading: storage.Reading,
    digest: [32]u8 = undefined,
};

pub fn readObservationContent(allocator: std.mem.Allocator, io: std.Io, request: *const storage.ContentRequest) !*const storage.Reading {
    const result = try allocator.create(ReadResult);
    result.fact = .{ .kind = .Missing, .tag = 0, .digest = &.{}, .physical_path = "" };
    result.reading = .{ .fact = &result.fact, .verified = null };

    readContent(io, allocator, request, result) catch |err| {
        result.fact = .{ .kind = .Failed, .tag = @intFromError(err), .digest = &.{}, .physical_path = "" };
    };

    return &result.reading;
}

fn readContent(io: std.Io, allocator: std.mem.Allocator, request: *const storage.ContentRequest, result: *ReadResult) !void {
    const path = request.path;

    if (request.directory) {
        result.digest = try storage.directory.digest(io, allocator, path, request.directory_entries);

        result.fact = .{
            .kind = .Directory,
            .tag = 0,
            .digest = &result.digest,
            .physical_path = try physicalPath(io, allocator, path),
        };

        return;
    }

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };

    defer file.close(io);

    const before = if (request.started != null) try file.stat(io) else undefined;

    result.digest = @import("artifact_io").digestFile(io, file) catch return error.ReadFailed;

    const physical = try physicalPath(io, allocator, path);

    if (request.started) |time| {
        const started = nanos(time);
        const after = try file.stat(io);
        const metadata = metadataOf(after);

        if (before.kind == .file and after.kind == .file and versions.residentMark(metadataOf(before), metadata, started, .{}) != null) {
            const verified = try allocator.create(VersionFields);

            verified.init(.{ .metadata = metadata, .read_at = started });

            result.reading.verified = &verified.view;
        }
    }

    result.fact = .{ .kind = .File, .tag = 0, .digest = &result.digest, .physical_path = physical };
}

pub const VersionFields = struct {
    modified: storage.Timestamp,
    changed: storage.Timestamp,
    read_at: storage.Timestamp,
    view: storage.FileVersion,
    pub fn init(self: *VersionFields, value: Snapshot.VerifiedFile) void {
        const metadata = value.metadata;

        self.modified = timestamp(metadata.mtime);
        self.changed = timestamp(metadata.ctime);
        self.read_at = timestamp(value.read_at);

        self.view = .{
            .inode = metadata.inode,
            .size = metadata.size,
            .modified = &self.modified,
            .changed = &self.changed,
            .read_at = &self.read_at,
        };
    }
};

pub fn versionFromFields(value: *const storage.FileVersion) Snapshot.VerifiedFile {
    return .{
        .metadata = .{
            .inode = value.inode,
            .size = value.size,
            .mtime = nanos(value.modified),
            .ctime = nanos(value.changed),
        },
        .read_at = nanos(value.read_at),
    };
}

pub fn timestamp(value: i96) storage.Timestamp {
    const time = versions.timestamp(value);

    return .{ .high = time.high, .low = time.low };
}

fn nanos(value: *const storage.Timestamp) i96 {
    const high: u32 = @bitCast(value.high);

    return @bitCast((@as(u96, high) << 64) | value.low);
}

pub fn physicalPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    const resolved = buffer[0..length];

    return if (std.mem.eql(u8, resolved, path)) path else allocator.dupe(u8, resolved);
}

pub fn statPath(io: std.Io, path: []const u8) !?std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
}

pub fn metadataOf(stat: std.Io.File.Stat) versions.Metadata {
    return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
}
