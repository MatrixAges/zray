const std = @import("std");
const bundle = @import("bundle");
const constants = @import("../../toolchain.zig").constants;
const extract = @import("../extract.zig");
const Error = error{ToolchainHostFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: ?[]const u8 = null,
    lock: ?std.Io.File = null,
    directory: ?std.Io.Dir = null,
    archive: ?[]const u8 = null,
    marker_buffer: [constants.marker_limit + 1]u8 = undefined,
    failure: ?anyerror = null,
    pub fn deinit(self: *State) void {
        self.close();

        if (self.staging) |path| std.Io.Dir.cwd().deleteTree(self.io, path) catch {};

        if (!extract.embedded) {
            if (self.archive) |archive| self.allocator.free(archive);
        }

        self.releaseLock();
    }
    fn close(self: *State) void {
        if (self.directory) |directory| directory.close(self.io);

        self.directory = null;
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

pub fn resolveExecutable(handle: *const anyopaque, path: []const u8) Error![]const u8 {
    const self = State.get(handle);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator) catch return self.fail(error.ZxcZigNotFound);
}

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

    self.directory = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.fail(err),
    };

    return true;
}

pub fn marker(handle: *const anyopaque) Error![]const u8 {
    const self = State.get(handle);
    const text = self.directory.?.readFile(self.io, constants.ready_file, &self.marker_buffer) catch return self.fail(error.IncompleteToolchainCache);

    if (text.len > constants.marker_limit) return self.fail(error.IncompleteToolchainCache);

    return text;
}

pub fn regularFile(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = State.get(handle);
    const file = self.directory.?.openFile(self.io, path, .{}) catch return self.fail(error.IncompleteToolchainCache);

    defer file.close(self.io);

    const info = file.stat(self.io) catch |err| return self.fail(err);

    return info.kind == .file and info.size != 0;
}

pub fn closeDirectory(handle: *const anyopaque) void {
    State.get(handle).close();
}

pub fn createStaging(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const cwd: std.Io.Dir = .cwd();

    cwd.deleteTree(self.io, path) catch |err| return self.fail(err);
    cwd.createDirPath(self.io, path) catch |err| return self.fail(err);

    self.staging = path;
    self.directory = cwd.openDir(self.io, path, .{}) catch |err| return self.fail(err);
}

pub fn loadZig(handle: *const anyopaque) Error![]const u8 {
    const self = State.get(handle);
    const archive = extract.zigArchive(self.io, self.allocator) catch |err| return self.fail(err);

    self.archive = archive;

    return archive;
}

pub fn extractZip(handle: *const anyopaque, archive: []const u8) Error!void {
    const self = State.get(handle);

    extract.zip(self.io, self.directory.?, archive) catch |err| return self.fail(err);
}

pub fn extractTar(handle: *const anyopaque, archive: []const u8) Error!void {
    const self = State.get(handle);

    extract.tar(self.io, self.allocator, self.directory.?, archive) catch |err| return self.fail(err);
}

pub fn renameZig(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const directory = self.directory.?;

    directory.rename(bundle.zig_directory, directory, constants.zig_directory, self.io) catch |err| return self.fail(err);

    if (!extract.embedded) self.allocator.free(self.archive.?);

    self.archive = null;
}

pub fn extractStandard(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    extract.resources(self.io, self.allocator, self.directory.?) catch |err| return self.fail(err);
}

pub fn publish(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const cwd: std.Io.Dir = .cwd();

    cwd.rename(self.staging.?, cwd, path, self.io) catch |err| return self.fail(err);

    self.staging = null;
}

pub fn unlock(handle: *const anyopaque) void {
    State.get(handle).releaseLock();
}

pub fn probeLibrary(handle: *const anyopaque, executable: []const u8, suffix: []const u8) Error!?[]const u8 {
    const self = State.get(handle);
    const parent = std.fs.path.dirname(executable) orelse return null;
    const candidate = std.fs.path.resolve(self.allocator, &.{ parent, suffix }) catch |err| return self.fail(err);

    errdefer self.allocator.free(candidate);

    const path = std.fs.path.join(self.allocator, &.{ candidate, constants.library_probe }) catch |err| return self.fail(err);

    defer self.allocator.free(path);

    std.Io.Dir.cwd().access(self.io, path, .{}) catch {
        self.allocator.free(candidate);

        return null;
    };

    return candidate;
}
