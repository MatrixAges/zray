const std = @import("std");
const builtin = @import("builtin");
const store = @import("../../store.zig");
const archive = store.archive;
const receipt = store.receipt;
const transfer = @import("../download.zig");
const constants = store.constants;
pub const Error = error{PackageCacheFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    bytes: ?[]const u8 = null,
    downloaded: ?transfer.Downloaded = null,
    staging: ?[]const u8 = null,
    failure: ?anyerror = null,
    pub fn deinit(self: *State) void {
        if (self.staging) |staging| std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};

        if (self.downloaded) |*payload| {
            payload.deinit();
        } else if (self.bytes) |bytes| {
            self.allocator.free(bytes);
        }
    }

    fn get(handle: *const anyopaque) *State {
        const reference: *const *State = @ptrCast(@alignCast(handle));

        return reference.*;
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.PackageCacheFailure;
    }
};

pub fn cached(handle: *const anyopaque, destination: []const u8, hex: []const u8) Error!bool {
    const self = State.get(handle);
    const io = self.io;

    var directory = std.Io.Dir.cwd().openDir(io, destination, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.fail(err),
    };

    defer directory.close(io);
    receipt.verify(io, self.temporary, directory, hex) catch |err| return self.fail(err);

    return true;
}

pub fn readBlob(handle: *const anyopaque, path: []const u8) Error!?[]const u8 {
    const self = State.get(handle);

    self.bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(archive.maximum_archive + 1)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return self.fail(err),
    };

    return self.bytes;
}

pub fn download(handle: *const anyopaque, source: []const u8, base: []const u8) Error![]const u8 {
    const self = State.get(handle);

    self.downloaded = transfer.read(self.io, self.allocator, source, base) catch |err| return self.fail(err);

    return self.downloaded.?.bytes;
}

pub fn createStaging(handle: *const anyopaque, root: []const u8) Error![]const u8 {
    const self = State.get(handle);
    const io = self.io;
    const temporary = self.temporary;
    var random: [16]u8 = undefined;

    std.Io.random(io, &random);

    const staging = std.fmt.allocPrint(temporary, "{s}/{s}/.prepare-{s}", .{ root, constants.content_directory, std.fmt.bytesToHex(random, .lower) }) catch |err| return self.fail(err);
    const content = std.fs.path.join(temporary, &.{ root, constants.content_directory }) catch |err| return self.fail(err);

    std.Io.Dir.cwd().createDirPath(io, content) catch |err| return self.fail(err);
    std.Io.Dir.cwd().createDir(io, staging, .default_dir) catch |err| return self.fail(err);

    self.staging = staging;

    return staging;
}

pub fn unpack(handle: *const anyopaque, staging: []const u8, bytes: []const u8, hex: []const u8) Error![]const u8 {
    const self = State.get(handle);
    const io = self.io;
    const directory = std.Io.Dir.cwd().openDir(io, staging, .{ .follow_symlinks = false }) catch |err| return self.fail(err);

    defer directory.close(io);
    directory.createDir(io, constants.package_directory, .default_dir) catch |err| return self.fail(err);

    var package = directory.openDir(io, constants.package_directory, .{}) catch |err| return self.fail(err);

    defer package.close(io);

    var extracted = archive.unpack(io, self.allocator, .{ .source = bytes }, package) catch |err| return self.fail(err);

    defer extracted.deinit();

    return std.json.Stringify.valueAlloc(self.temporary, receipt.Receipt{ .archive_sha256 = hex, .files = extracted.files }, .{}) catch |err| self.fail(err);
}

pub fn publishStaging(handle: *const anyopaque, staging: []const u8, destination: []const u8) Error!bool {
    const self = State.get(handle);
    const io = self.io;

    const moved: std.Io.Dir.RenamePreserveError!void = if (builtin.os.tag == .windows or builtin.os.tag == .linux)
        std.Io.Dir.cwd().renamePreserve(staging, .cwd(), destination, io)

    else
        std.Io.Dir.cwd().rename(staging, .cwd(), destination, io);

    moved catch |err| switch (err) {
        error.PathAlreadyExists, error.DirNotEmpty => return false,
        else => return self.fail(err),
    };

    return true;
}
