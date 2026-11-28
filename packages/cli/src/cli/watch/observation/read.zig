const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const versions = @import("compiler").input_snapshot;
const storage = @import("storage.zig");
const Error = storage.Error;
const rule = @import("cli_source").read;

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8 = undefined,
    scan: ?Scan = null,
    started: i96 = 0,
    save_version: bool = false,
    verified_file: ?Snapshot.VerifiedFile = null,
    result: Snapshot.State = undefined,
    left: storage.Fact = undefined,
    right: storage.Fact = undefined,
    comparison: storage.Comparison = undefined,
    failure: ?anyerror = null,
    pub const Scan = struct {
        entries: []Snapshot.Entry,
        scratch: *std.heap.ArenaAllocator,
    };
    pub fn get(handle: *const anyopaque) *Context {
        return storage.context(Context, handle);
    }

    pub fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

pub fn observe(self: *Context, directory_entries: bool) !void {
    const handle = self;

    const classified = rule.executeIn(self.allocator, &.{
        .observation = @ptrCast(&handle),
        .path = self.path,
        .directory_entries = directory_entries,
    }, self.io) catch |err| return if (err == error.ObservationFailure) self.failure.? else err;

    if (classified) |value| {
        self.result = switch (value.kind) {
            .Missing => .missing,
            .Other => .{ .other = @fromBackingInt(@intCast(value.tag)) },
            else => unreachable,
        };
    }
}

pub fn classify(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*const storage.Classification {
    const stat = (try statPath(io, path)) orelse return &.{ .kind = .Missing, .tag = 0 };

    return switch (stat.kind) {
        .file => &.{ .kind = .File, .tag = 0 },
        .directory => &.{ .kind = .Directory, .tag = 0 },
        else => |kind| other: {
            const info = try allocator.create(storage.Classification);

            info.* = .{ .kind = .Other, .tag = @backingInt(kind) };

            break :other info;
        },
    };
}

pub fn readDirectory(handle: *const anyopaque, all_entries: bool) Error!void {
    const self = Context.get(handle);
    const digest = storage.directory.digest(self.io, self.allocator, self.path, all_entries) catch |err| return self.fail(err);
    const path = physicalPath(self.io, self.allocator, self.path) catch |err| return self.fail(err);

    self.result = .{ .directory = .{ .digest = digest, .physical_path = path } };
}

pub fn readFile(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    observeFile(self) catch |err| return self.fail(err);
}

fn observeFile(self: *Context) !void {
    const file = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            self.result = .missing;

            return;
        },
        else => return err,
    };

    defer file.close(self.io);

    const before = if (self.save_version) try file.stat(self.io) else undefined;
    const digest = @import("artifact_io").digestFile(self.io, file) catch return error.ReadFailed;
    const physical = try physicalPath(self.io, self.allocator, self.path);

    if (self.save_version) {
        const after = try file.stat(self.io);
        const metadata = metadataOf(after);

        if (before.kind == .file and after.kind == .file and versions.residentMark(metadataOf(before), metadata, self.started, .{}) != null) {
            self.verified_file = .{ .metadata = metadata, .read_at = self.started };
        }
    }

    self.result = .{ .file = .{ .digest = digest, .physical_path = physical } };
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
