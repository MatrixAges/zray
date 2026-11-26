const std = @import("std");
const abi = @import("cli_abi");
const File = @import("../../archive.zig").File;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Entry = abi.layouts.@"zig:package_extract_host".Entry;
pub const Error = error{ArchiveHostFailure};

pub const State = struct {
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    iterator: *std.tar.Iterator,
    entry: std.tar.Iterator.File = undefined,
    entry_view: Entry = undefined,
    files: std.ArrayList(File) = .empty,
    failure: ?anyerror = null,
    fn get(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.ArchiveHostFailure;
    }
};

pub fn nextTar(handle: *anyopaque) Error!?*const Entry {
    const self = State.get(handle);

    self.entry = (self.iterator.next() catch |err| return self.fail(err)) orelse return null;

    self.entry_view = .{
        .name = self.entry.name,
        .kind = switch (self.entry.kind) {
            .directory => .Directory,
            .file => .File,
            else => .Other,
        },
        .executable = self.entry.mode & 0o100 != 0,
    };

    return &self.entry_view;
}

pub fn makeTarDirectory(handle: *anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);

    self.directory.createDirPath(self.io, path) catch |err| return self.fail(err);
}

pub fn writeTarFile(handle: *anyopaque, path: []const u8, executable: bool) Error!void {
    const self = State.get(handle);
    const io = self.io;
    const directory = self.directory;
    const owned_path = self.allocator.dupe(u8, path) catch |err| return self.fail(err);

    if (std.fs.path.dirname(owned_path)) |parent| directory.createDirPath(io, parent) catch |err| return self.fail(err);

    const file = directory.createFile(io, owned_path, .{ .exclusive = true, .permissions = if (executable) .executable_file else .default_file }) catch |err| return self.fail(err);

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

    self.files.append(self.allocator, .{ .path = owned_path, .sha256 = digest, .executable = executable }) catch |err| return self.fail(err);
}
