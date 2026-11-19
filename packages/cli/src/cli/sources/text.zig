const std = @import("std");
const Read = struct { bytes: []const u8, fresh: bool };
const limit = 16 * 1024 * 1024;

/// Holds the raw source of each file for one set of library exports.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    pub fn deinit(self: *Cache) void {
        self.files.deinit(self.allocator);
    }
    fn read(self: *Cache, io: std.Io, path: []const u8) !Read {
        if (self.files.get(path)) |bytes| return .{ .bytes = bytes, .fresh = false };

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(limit));

        errdefer self.allocator.free(bytes);

        const key = try self.allocator.dupe(u8, path);

        errdefer self.allocator.free(key);

        try self.files.put(self.allocator, key, bytes);

        return .{ .bytes = bytes, .fresh = true };
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8, cache: ?*Cache) !Read {
    if (cache) |batch| return batch.read(io, path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));

    return .{ .bytes = bytes, .fresh = true };
}
