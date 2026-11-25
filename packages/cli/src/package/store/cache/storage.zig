const std = @import("std");
const builtin = @import("builtin");
const store = @import("../../store.zig");
const archive = store.archive;
const receipt = store.receipt;
const constants = store.constants;
pub const Error = error{PackageCacheFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    source: []const u8,
    source_base: []const u8,
    root: []const u8,
    destination: []const u8,
    digest: [32]u8,
    hex: []const u8,
    blob_path: []const u8 = undefined,
    bytes: ?[]u8 = null,
    verified: archive.Verified = undefined,
    staging: ?[]const u8 = null,
    directory: ?std.Io.Dir = null,
    extracted: ?archive.Result = null,
    failure: ?anyerror = null,
    pub fn deinit(self: *State) void {
        self.close();

        if (self.staging) |staging| std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};
        if (self.bytes) |bytes| self.allocator.free(bytes);
    }
    fn close(self: *State) void {
        if (self.extracted) |*extracted| extracted.deinit();
        if (self.directory) |directory| directory.close(self.io);

        self.extracted = null;
        self.directory = null;
    }

    fn get(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.PackageCacheFailure;
    }
};

pub fn cached(handle: *anyopaque) Error!bool {
    const self = State.get(handle);
    const io = self.io;

    var directory = std.Io.Dir.cwd().openDir(io, self.destination, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.fail(err),
    };

    defer directory.close(io);
    receipt.verify(io, self.temporary, directory, self.hex) catch |err| return self.fail(err);

    return true;
}

pub fn readBlob(handle: *anyopaque) Error!bool {
    const self = State.get(handle);
    const path = std.fmt.allocPrint(self.temporary, "{s}/{s}/{s}.tar.gz", .{ self.root, constants.archive_directory, self.hex }) catch |err| return self.fail(err);

    self.blob_path = path;

    self.bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(archive.maximum_archive + 1)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.fail(err),
    };

    return true;
}

pub fn download(handle: *anyopaque) Error!void {
    const self = State.get(handle);

    self.bytes = @import("../download.zig").read(self.io, self.allocator, self.source, self.source_base) catch |err| return self.fail(err);
}

pub fn verifyBlob(handle: *anyopaque) Error!void {
    const self = State.get(handle);

    self.verified = archive.verify(self.bytes.?, self.digest) catch |err| return self.fail(err);
}

pub fn createStaging(handle: *anyopaque) Error!void {
    const self = State.get(handle);
    const io = self.io;
    const temporary = self.temporary;
    var random: [16]u8 = undefined;

    std.Io.random(io, &random);

    const staging = std.fmt.allocPrint(temporary, "{s}/{s}/.prepare-{s}", .{ self.root, constants.content_directory, std.fmt.bytesToHex(random, .lower) }) catch |err| return self.fail(err);
    const content = std.fs.path.join(temporary, &.{ self.root, constants.content_directory }) catch |err| return self.fail(err);

    std.Io.Dir.cwd().createDirPath(io, content) catch |err| return self.fail(err);
    std.Io.Dir.cwd().createDir(io, staging, .default_dir) catch |err| return self.fail(err);

    self.staging = staging;
}

pub fn unpack(handle: *anyopaque) Error!void {
    const self = State.get(handle);
    const io = self.io;
    const directory = std.Io.Dir.cwd().openDir(io, self.staging.?, .{}) catch |err| return self.fail(err);

    self.directory = directory;

    directory.createDir(io, constants.package_directory, .default_dir) catch |err| return self.fail(err);

    var package = directory.openDir(io, constants.package_directory, .{}) catch |err| return self.fail(err);

    defer package.close(io);

    self.extracted = archive.unpack(io, self.allocator, self.verified, package) catch |err| return self.fail(err);
}

pub fn writeReceipt(handle: *anyopaque) Error!void {
    const self = State.get(handle);
    const temporary = self.temporary;
    const text = std.json.Stringify.valueAlloc(temporary, receipt.Receipt{ .archive_sha256 = self.hex, .files = self.extracted.?.files }, .{}) catch |err| return self.fail(err);
    const path = std.fs.path.join(temporary, &.{ self.staging.?, constants.receipt_file }) catch |err| return self.fail(err);

    write(self.io, path, text) catch |err| return self.fail(err);
}

pub fn checkStaging(handle: *anyopaque) Error!void {
    const self = State.get(handle);

    receipt.verify(self.io, self.allocator, self.directory.?, self.hex) catch |err| return self.fail(err);
}

pub fn closeStaging(handle: *anyopaque) void {
    State.get(handle).close();
}

pub fn publishBlob(handle: *anyopaque) Error!void {
    const self = State.get(handle);

    write(self.io, self.blob_path, self.bytes.?) catch |err| return self.fail(err);
}

pub fn publishStaging(handle: *anyopaque) Error!bool {
    const self = State.get(handle);
    const io = self.io;
    const staging = self.staging.?;

    const moved: std.Io.Dir.RenamePreserveError!void = if (builtin.os.tag == .windows or builtin.os.tag == .linux)
        std.Io.Dir.cwd().renamePreserve(staging, .cwd(), self.destination, io)

    else
        std.Io.Dir.cwd().rename(staging, .cwd(), self.destination, io);

    moved catch |err| switch (err) {
        error.PathAlreadyExists, error.DirNotEmpty => return false,
        else => return self.fail(err),
    };

    return true;
}

fn write(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, content);
    try file.replace(io);
}
