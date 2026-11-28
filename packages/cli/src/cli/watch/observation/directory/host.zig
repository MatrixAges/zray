const std = @import("std");
const storage = @import("../storage.zig");
const source = @import("cli_source").directory_digest;
const Hash = std.crypto.hash.sha2.Sha256;
const View = @import("cli_abi").layouts.@"zig:snapshot_host".DirectoryEntry;
const StoreState = std.meta.Child(@FieldType(source.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

const Cursor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    iterator: std.Io.Dir.Iterator,
    view: View = undefined,
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
    var collected: StoreState = &.{ .names = &.{}, .tags = &.{} };
    var host: StoreHost = .{ .store_0 = &collected };
    const hashed = source.execute(&arena, &.{ .directory = @ptrCast(&handle), .all_entries = all_entries }, &host) catch |err| return if (err == error.ObservationFailure) cursor.failure.? else err;

    return hashed[0..Hash.digest_length].*;
}

pub fn nextDirectoryEntry(handle: *const anyopaque) storage.Error!?*const View {
    const self = storage.context(Cursor, handle);
    const row = (self.iterator.next(self.io) catch |err| return self.fail(err)) orelse return null;
    const name = self.allocator.dupe(u8, row.name) catch |err| return self.fail(err);

    self.view = .{
        .name = name,
        .is_directory = row.kind == .directory,
        .kind_tag = @backingInt(row.kind),
    };

    return &self.view;
}
