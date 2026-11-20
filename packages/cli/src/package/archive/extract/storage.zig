const std = @import("std");
const File = @import("../../archive.zig").File;
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Error = error{ArchiveHostFailure};

pub const State = struct {
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    iterator: *std.tar.Iterator,
    entry: std.tar.Iterator.File = undefined,
    path: []const u8 = undefined,
    paths: std.StringHashMapUnmanaged(void) = .empty,
    files: std.ArrayList(File) = .empty,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.ArchiveHostFailure;
    }
};

pub fn nextTar(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.entry = (self.iterator.next() catch |err| return self.fail(err)) orelse return false;

    return true;
}

pub fn tarName(handle: *const anyopaque) []const u8 {
    return State.get(handle).entry.name;
}

pub fn tarDirectory(handle: *const anyopaque) bool {
    return State.get(handle).entry.kind == .directory;
}

pub fn tarFile(handle: *const anyopaque) bool {
    return State.get(handle).entry.kind == .file;
}

pub fn tarExecutable(handle: *const anyopaque) bool {
    return State.get(handle).entry.mode & 0o100 != 0;
}

pub fn claimTarPath(handle: *const anyopaque, name: []const u8) Error!bool {
    const self = State.get(handle);
    const path = self.allocator.dupe(u8, name) catch |err| return self.fail(err);
    const previous = self.paths.getOrPut(self.allocator, path) catch |err| return self.fail(err);

    self.path = path;

    return !previous.found_existing;
}

pub fn makeTarDirectory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.directory.createDirPath(self.io, self.path) catch |err| return self.fail(err);
}

pub fn writeTarFile(handle: *const anyopaque, executable: bool) Error!void {
    const self = State.get(handle);
    const io = self.io;
    const directory = self.directory;
    const path = self.path;

    if (std.fs.path.dirname(path)) |parent| directory.createDirPath(io, parent) catch |err| return self.fail(err);

    const file = directory.createFile(io, path, .{ .exclusive = true, .permissions = if (executable) .executable_file else .default_file }) catch |err| return self.fail(err);

    defer file.close(io);

    var output_buffer: [65536]u8 = undefined;
    var hash_buffer: [65536]u8 = undefined;
    var output = file.writer(io, &output_buffer);
    var hashed = std.Io.Writer.Hashed(Sha256).initHasher(&output.interface, .init(.{}), &hash_buffer);

    self.iterator.streamRemaining(self.entry, &hashed.writer) catch |err| return self.fail(err);
    hashed.writer.flush() catch |err| return self.fail(err);
    output.interface.flush() catch |err| return self.fail(err);

    const hex = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower);
    const digest = self.allocator.dupe(u8, &hex) catch |err| return self.fail(err);

    self.files.append(self.allocator, .{ .path = path, .sha256 = digest, .executable = executable }) catch |err| return self.fail(err);
}
