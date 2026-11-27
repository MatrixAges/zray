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

fn recordCachedSource(frame: *const CachedRows, index: usize) Error!void {
    const found = frame.lookups[index];

    _ = try frame.cache.record(found.name, found.key, &frame.fetched[index]);
}

pub fn recordCachedPrefix(handle: *const anyopaque, count: u64) Error!void {
    const frame: *const CachedRows = @ptrCast(@alignCast(handle));

    for (0..@as(usize, @intCast(count))) |index| try recordCachedSource(frame, index);
}

pub fn tryRecordCachedSource(handle: *const anyopaque, row: u64) bool {
    const frame: *const CachedRows = @ptrCast(@alignCast(handle));

    recordCachedSource(frame, @intCast(row)) catch return false;

    return true;
}

pub fn accountCachedSources(handle: *const anyopaque, held: u64, discarded: u64, failures: u64, last: ?u64) void {
    const frame: *const CachedRows = @ptrCast(@alignCast(handle));
    const cache = frame.cache;
    cache.reused += @intCast(held);
    cache.discarded += @intCast(discarded);
    cache.io_errors += @intCast(failures);

    if (last) |index| cache.last_io_error = frame.fetched[@intCast(index)].failure.?;
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
