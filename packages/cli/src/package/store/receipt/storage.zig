const std = @import("std");
const archive = @import("../../archive.zig");
const Receipt = @import("../receipt.zig").Receipt;
const constants = @import("cli_source").store_constants.@"zx.constants";
pub const Error = error{ReceiptHostFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    expected: []const u8,
    source: ?[]u8 = null,
    parsed: ?std.json.Parsed(Receipt) = null,
    names: std.StringHashMapUnmanaged(usize) = .empty,
    package: ?std.Io.Dir = null,
    walker: ?std.Io.Dir.Walker = null,
    entry: std.Io.Dir.Walker.Entry = undefined,
    file: ?std.Io.File = null,
    stat: std.Io.File.Stat = undefined,
    digest: [64]u8 = undefined,
    failure: ?anyerror = null,
    fn get(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.ReceiptHostFailure;
    }
    fn closeFile(self: *State) void {
        if (self.file) |file| file.close(self.io);

        self.file = null;
    }
    pub fn deinit(self: *State) void {
        self.closeFile();

        if (self.walker) |*walker| {
            while (walker.inner.stack.items.len != 0) walker.leave(self.io);

            walker.deinit();
        }

        if (self.package) |directory| directory.close(self.io);

        self.names.deinit(self.allocator);

        if (self.parsed) |parsed| parsed.deinit();
        if (self.source) |source| self.allocator.free(source);
    }
};

pub fn receiptIsFile(handle: *anyopaque) Error!bool {
    const self = State.get(handle);
    const stat = self.directory.statFile(self.io, constants.receipt_file, .{ .follow_symlinks = false }) catch |err| return self.fail(err);

    return stat.kind == .file;
}

pub fn loadReceipt(handle: *anyopaque) Error!void {
    const self = State.get(handle);
    const io = self.io;
    const file = self.directory.openFile(io, constants.receipt_file, .{ .follow_symlinks = false }) catch |err| return self.fail(err);

    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const source = reader.interface.allocRemaining(self.allocator, .limited(archive.maximum_unpacked)) catch |err| return self.fail(err);

    self.source = source;
    self.parsed = std.json.parseFromSlice(Receipt, self.allocator, source, .{}) catch |err| return self.fail(err);
}

pub fn formatVersion(handle: *anyopaque) u32 {
    return State.get(handle).parsed.?.value.format_version;
}

pub fn archiveHash(handle: *anyopaque) []const u8 {
    return State.get(handle).parsed.?.value.archive_sha256;
}

pub fn requiredHash(handle: *anyopaque) []const u8 {
    return State.get(handle).expected;
}

pub fn fileCount(handle: *anyopaque) u64 {
    return State.get(handle).parsed.?.value.files.len;
}

pub fn filePath(handle: *anyopaque, row: u64) []const u8 {
    return State.get(handle).parsed.?.value.files[@intCast(row)].path;
}

pub fn fileHash(handle: *anyopaque, row: u64) []const u8 {
    return State.get(handle).parsed.?.value.files[@intCast(row)].sha256;
}

pub fn expectedExecutable(handle: *anyopaque, row: u64) bool {
    return State.get(handle).parsed.?.value.files[@intCast(row)].executable;
}

pub fn claimFile(handle: *anyopaque, row: u64, path: []const u8) Error!bool {
    const self = State.get(handle);
    const entry = self.names.getOrPut(self.allocator, path) catch |err| return self.fail(err);

    if (entry.found_existing) return false;

    entry.value_ptr.* = @intCast(row);

    return true;
}

pub fn openTree(handle: *anyopaque) Error!void {
    const self = State.get(handle);
    const package = self.directory.openDir(self.io, constants.package_directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| return self.fail(err);
    self.package = package;
    self.walker = package.walk(self.allocator) catch |err| return self.fail(err);
}

pub fn nextTreeEntry(handle: *anyopaque) Error!bool {
    const self = State.get(handle);

    self.entry = (self.walker.?.next(self.io) catch |err| return self.fail(err)) orelse return false;

    return true;
}

pub fn treeDirectory(handle: *anyopaque) bool {
    return State.get(handle).entry.kind == .directory;
}

pub fn treeFile(handle: *anyopaque) bool {
    return State.get(handle).entry.kind == .file;
}

pub fn lookupFile(handle: *anyopaque) Error!?u64 {
    const self = State.get(handle);

    if (comptime std.fs.path.sep == '/') return self.names.get(self.entry.path);

    const path = self.allocator.dupe(u8, self.entry.path) catch |err| return self.fail(err);

    defer self.allocator.free(path);
    std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');

    return self.names.get(path);
}

pub fn openTreeFile(handle: *anyopaque) Error!void {
    const self = State.get(handle);
    const file = self.package.?.openFile(self.io, self.entry.path, .{}) catch |err| return self.fail(err);

    self.file = file;
    self.stat = file.stat(self.io) catch |err| return self.fail(err);
}

pub fn permissionsMatch(handle: *anyopaque, expected: bool) bool {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return true;

    return (State.get(handle).stat.permissions.toMode() & 0o100 != 0) == expected;
}

pub fn hashTreeFile(handle: *anyopaque, remaining: u64) Error!?u64 {
    const self = State.get(handle);
    var buffer: [65536]u8 = undefined;
    var reader_buffer: [65536]u8 = undefined;
    var reader = self.file.?.reader(self.io, &reader_buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var length: u64 = 0;

    while (true) {
        const size = reader.interface.readSliceShort(&buffer) catch |err| return self.fail(err);

        if (size == 0) break;
        if (size > remaining - length) return null;

        length += size;

        hash.update(buffer[0..size]);
    }

    self.digest = std.fmt.bytesToHex(hash.finalResult(), .lower);

    return length;
}

pub fn currentHash(handle: *anyopaque) []const u8 {
    return &State.get(handle).digest;
}

pub fn closeTreeFile(handle: *anyopaque) void {
    State.get(handle).closeFile();
}
