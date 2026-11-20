const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const versions = @import("compiler").input_snapshot;
const storage = @import("storage.zig");
const Error = storage.Error;
const rule = @import("watch_observation").read;

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    started: i96 = 0,
    save_version: bool = false,
    verified_file: ?Snapshot.VerifiedFile = null,
    result: Snapshot.State = undefined,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

pub fn observe(self: *Context, directory_entries: bool) !void {
    rule.executeValue(self.allocator, &.{ .observation = @ptrCast(self), .directory_entries = directory_entries }) catch |err| return if (err == error.ObservationFailure) self.failure.? else err;
}

pub fn classify(handle: *const anyopaque) Error!storage.PathKind {
    const self = Context.get(handle);

    const stat = (statPath(self.io, self.path) catch |err| return self.fail(err)) orelse {
        self.result = .missing;

        return .Classified;
    };

    return switch (stat.kind) {
        .file => .File,
        .directory => .Directory,
        else => blk: {
            self.result = .{ .other = stat.kind };

            break :blk .Classified;
        },
    };
}

pub fn fullDirectory(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);
    const digest = @import("../directory.zig").digest(self.io, self.allocator, self.path) catch |err| return self.fail(err);

    return completeDirectory(self, digest);
}

pub fn workspaceDirectory(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);
    const digest = @import("../../../package/workspace/directory.zig").digest(self.io, self.allocator, self.path) catch |err| return self.fail(err);

    return completeDirectory(self, digest);
}

fn completeDirectory(self: *Context, digest: [32]u8) Error!void {
    const path = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.path, self.allocator) catch |err| return self.fail(err);

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
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(self.io, &buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});

    while (true) {
        const data = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        hash.update(data);
        reader.interface.tossBuffered();
    }

    const digest = hash.finalResult();
    const physical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, self.path, self.allocator);

    if (self.save_version) {
        const after = try file.stat(self.io);
        const metadata = metadataOf(after);

        if (before.kind == .file and after.kind == .file and versions.residentMark(metadataOf(before), metadata, self.started, .{}) != null) {
            self.verified_file = .{ .metadata = metadata, .read_at = self.started };
        }
    }

    self.result = .{ .file = .{ .digest = digest, .physical_path = physical } };
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
