const std = @import("std");
const constants = @import("../../toolchain.zig").constants;
const extract = @import("../extract.zig");
const Error = error{ToolchainHostFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: ?[]const u8 = null,
    lock: ?std.Io.File = null,
    archive: ?[]const u8 = null,
    failure: ?anyerror = null,
    pub fn deinit(self: *State) void {
        if (self.staging) |path| std.Io.Dir.cwd().deleteTree(self.io, path) catch {};

        self.releaseArchive();
        self.releaseLock();
    }

    fn releaseArchive(self: *State) void {
        if (!extract.embedded) {
            if (self.archive) |archive| self.allocator.free(archive);
        }

        self.archive = null;
    }

    fn releaseLock(self: *State) void {
        if (self.lock) |file| file.close(self.io);

        self.lock = null;
    }

    fn get(handle: *const anyopaque) *State {
        const reference: *const *State = @ptrCast(@alignCast(handle));

        return reference.*;
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.ToolchainHostFailure;
    }
};

pub fn lockCache(handle: *const anyopaque, parent: []const u8, path: []const u8) Error!void {
    const self = State.get(handle);
    const cwd: std.Io.Dir = .cwd();

    cwd.createDirPath(self.io, parent) catch |err| return self.fail(err);

    const lock = cwd.createFile(self.io, path, .{ .truncate = false }) catch |err| return self.fail(err);

    self.lock = lock;

    lock.lock(self.io, .exclusive) catch |err| return self.fail(err);
}

pub fn openCache(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = State.get(handle);

    const directory = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.fail(err),
    };

    directory.close(self.io);

    return true;
}

pub fn marker(allocator: std.mem.Allocator, handle: *const anyopaque, directory: []const u8) Error![]const u8 {
    const self = State.get(handle);
    const dir = std.Io.Dir.cwd().openDir(self.io, directory, .{}) catch return self.fail(error.IncompleteToolchainCache);

    defer dir.close(self.io);

    var buffer: [constants.marker_limit + 1]u8 = undefined;
    const text = dir.readFile(self.io, constants.ready_file, &buffer) catch return self.fail(error.IncompleteToolchainCache);

    if (text.len > constants.marker_limit) return self.fail(error.IncompleteToolchainCache);

    return allocator.dupe(u8, text) catch |err| self.fail(err);
}

pub fn regularFile(handle: *const anyopaque, directory: []const u8, path: []const u8) Error!bool {
    const self = State.get(handle);
    const dir = std.Io.Dir.cwd().openDir(self.io, directory, .{}) catch return self.fail(error.IncompleteToolchainCache);

    defer dir.close(self.io);

    const file = dir.openFile(self.io, path, .{}) catch return self.fail(error.IncompleteToolchainCache);

    defer file.close(self.io);

    const info = file.stat(self.io) catch |err| return self.fail(err);

    return info.kind == .file and info.size != 0;
}

pub fn createStaging(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const cwd: std.Io.Dir = .cwd();

    cwd.deleteTree(self.io, path) catch |err| return self.fail(err);
    cwd.createDirPath(self.io, path) catch |err| return self.fail(err);

    self.staging = path;
}

pub fn loadZig(handle: *const anyopaque) Error![]const u8 {
    const self = State.get(handle);
    const archive = extract.zigArchive(self.io, self.allocator) catch |err| return self.fail(err);

    self.archive = archive;

    return archive;
}

pub fn extractZip(handle: *const anyopaque, path: []const u8, archive: []const u8) Error!void {
    const self = State.get(handle);

    defer self.releaseArchive();

    const directory = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch |err| return self.fail(err);

    defer directory.close(self.io);
    extract.zip(self.io, directory, archive) catch |err| return self.fail(err);
}

pub fn extractTar(handle: *const anyopaque, path: []const u8, archive: []const u8) Error!void {
    const self = State.get(handle);

    defer self.releaseArchive();

    const directory = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch |err| return self.fail(err);

    defer directory.close(self.io);
    extract.tar(self.io, self.allocator, directory, archive) catch |err| return self.fail(err);
}

pub fn extractStandard(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const directory = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch |err| return self.fail(err);

    defer directory.close(self.io);
    extract.resources(self.io, self.allocator, directory) catch |err| return self.fail(err);
}

pub fn probeLibrary(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}
