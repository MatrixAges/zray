const std = @import("std");
const source = @import("cli_source").directory_digest;
const Hash = std.crypto.hash.sha2.Sha256;
const StoreState = std.meta.Child(@FieldType(source.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn digest(io: std.Io, allocator: std.mem.Allocator, path: []const u8, all_entries: bool) ![Hash.digest_length]u8 {
    const directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });

    defer directory.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    var rows: std.MultiArrayList(struct { name: []const u8, tag: u8 }) = .empty;
    var iterator = directory.iterate();

    while (try iterator.next(io)) |entry| {
        try rows.append(temporary, .{
            .name = try temporary.dupe(u8, entry.name),
            .tag = @backingInt(entry.kind),
        });
    }

    var collected: StoreState = &.{ .names = &.{}, .tags = &.{} };
    var host: StoreHost = .{ .store_0 = &collected };

    const hashed = try source.execute(&arena, &.{
        .all_entries = all_entries,
        .directory_tag = @backingInt(std.Io.File.Kind.directory),
        .names = rows.items(.name),
        .tags = rows.items(.tag),
    }, &host);

    return hashed[0..Hash.digest_length].*;
}
