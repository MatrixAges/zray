const std = @import("std");
const rx = @import("rx");
pub const Read = struct { bytes: []const u8, fresh: bool };
const Entry = struct { bytes: []const u8, xml: ?*const rx.IndexedXml = null };
const limit = 16 * 1024 * 1024;

/// Holds source bytes and parsed RX documents in the library analysis arena.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(Entry) = .empty,
    pub fn deinit(self: *Cache) void {
        self.files.deinit(self.allocator);
    }
    fn read(self: *Cache, io: std.Io, path: []const u8) !Read {
        if (self.files.get(path)) |entry| return .{ .bytes = entry.bytes, .fresh = false };

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(limit));

        errdefer self.allocator.free(bytes);

        const key = try self.allocator.dupe(u8, path);

        errdefer self.allocator.free(key);

        try self.files.put(self.allocator, key, .{ .bytes = bytes });

        return .{ .bytes = bytes, .fresh = true };
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8, cache: ?*Cache) !Read {
    if (cache) |batch| return batch.read(io, path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));

    return .{ .bytes = bytes, .fresh = true };
}

pub fn parseRx(allocator: std.mem.Allocator, cache: ?*Cache, path: []const u8, text: Read) !rx.IndexedXml {
    if (text.fresh) return rx.parseBorrowedIndexedXml(allocator, text.bytes);

    const batch = cache.?;
    const entry = batch.files.getPtr(path).?;

    if (entry.xml) |document| return document.*;

    const document = try batch.allocator.create(rx.IndexedXml);

    errdefer batch.allocator.destroy(document);

    document.* = try rx.parseBorrowedIndexedXml(batch.allocator, entry.bytes);
    entry.xml = document;

    return document.*;
}
