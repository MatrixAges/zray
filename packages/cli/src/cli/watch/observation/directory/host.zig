const std = @import("std");
const storage = @import("../storage.zig");
const source = @import("cli_source").directory_digest;
const Hash = std.crypto.hash.sha2.Sha256;
const View = @import("cli_abi").layouts.@"zig:snapshot_host".DirectoryEntry;

const Cursor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    iterator: std.Io.Dir.Iterator,
    entries: std.ArrayList([]const u8) = .empty,
    kind: std.Io.File.Kind = undefined,
    view: View = undefined,
    hash: Hash = .init(.{}),
    failure: ?anyerror = null,
    fn fail(self: *Cursor, err: anyerror) storage.Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

pub fn digest(io: std.Io, allocator: std.mem.Allocator, path: []const u8, all_entries: bool) ![Hash.digest_length]u8 {
    const directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });

    defer directory.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var cursor: Cursor = .{ .io = io, .allocator = arena.allocator(), .iterator = directory.iterate() };
    const handle = &cursor;

    source.executeIn(cursor.allocator, &.{ .directory = @ptrCast(&handle), .all_entries = all_entries }) catch |err| return if (err == error.ObservationFailure) cursor.failure.? else err;

    return cursor.hash.finalResult();
}

pub fn nextDirectoryEntry(handle: *const anyopaque) storage.Error!?*const View {
    const self = storage.context(Cursor, handle);
    const row = (self.iterator.next(self.io) catch |err| return self.fail(err)) orelse return null;

    self.kind = row.kind;
    self.view = .{ .name = row.name, .is_directory = row.kind == .directory };

    return &self.view;
}

pub fn retainDirectoryEntry(handle: *const anyopaque, separator: u8, suffix_width: u8) storage.Error!void {
    const self = storage.context(Cursor, handle);
    const name = self.view.name;
    const row = self.allocator.alloc(u8, name.len + suffix_width) catch |err| return self.fail(err);
    const suffix = [_]u8{ separator, @backingInt(self.kind) };

    @memcpy(row[0..name.len], name);
    @memcpy(row[name.len..], suffix[0..suffix_width]);
    self.entries.append(self.allocator, row) catch |err| return self.fail(err);
}

pub fn sortDirectoryEntries(handle: *const anyopaque, suffix_width: u8) u64 {
    const rows = storage.context(Cursor, handle).entries.items;

    std.mem.sort([]const u8, rows, @as(usize, suffix_width), lessThan);

    return rows.len;
}

fn lessThan(suffix_width: usize, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left[0 .. left.len - suffix_width], right[0 .. right.len - suffix_width]);
}

pub fn feedDirectoryEntry(handle: *const anyopaque, row: u64) void {
    const self = storage.context(Cursor, handle);

    self.hash.update(self.entries.items[@intCast(row)]);
}
