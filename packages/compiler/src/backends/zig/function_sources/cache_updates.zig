const std = @import("std");
const zx = @import("zx");
const Batch = @import("../batch.zig");
const Cache = @import("../cache.zig");
const Result = @import("publication.zig").Result;
const Error = std.mem.Allocator.Error;

pub const CachedRows = struct {
    cache: *Cache,
    lookups: []const Batch.Lookup,
    fetched: []Cache.Fetched,
};

const GeneratedRows = struct {
    cache: *Cache,
    lookups: []const Batch.Lookup,
    results: []Result,
};

pub fn commit(cache: *Cache, lookups: []const Batch.Lookup, results: []Result, positions: []const u64) Error!void {
    const frame: GeneratedRows = .{ .cache = cache, .lookups = lookups, .results = results };
    const entry = @import("generated_commit_pending_sources");
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    for (0..positions.len) |index| {
        const request: std.meta.Child(entry.Input) = .{ .positions = positions, .index = index };
        const update = zx.columns.invoke(entry.executeValue, fixed.allocator(), &request) catch unreachable;

        try commitSource(&frame, @intCast(update.position), @intCast(update.result));
    }
}

pub fn record(frame: *const CachedRows, first: usize, end: usize) Error!void {
    for (frame.lookups[first..end], frame.fetched[first..end]) |found, *fetched| {
        _ = try frame.cache.record(found.name, found.key, fetched);
    }
}

fn commitSource(frame: *const GeneratedRows, position: usize, index: usize) Error!void {
    const found = frame.lookups[position];
    const result = &frame.results[index];
    const cache = frame.cache;
    cache.generated += 1;

    try cache.putShared(found.name, found.key, result.owned.?);

    result.source = null;
    result.owned = null;
}
