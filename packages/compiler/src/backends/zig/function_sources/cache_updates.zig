const std = @import("std");
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
    const request: std.meta.Child(entry.Input) = .{ .target = @ptrCast(&frame), .positions = positions };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(fixed.allocator(), &request) catch |err| return failure(err);
}

pub fn recordCachedSource(handle: *const anyopaque, row: u64) Error!void {
    const frame: *const CachedRows = @ptrCast(@alignCast(handle));
    const index: usize = @intCast(row);
    const found = frame.lookups[index];

    _ = try frame.cache.record(found.name, found.key, &frame.fetched[index]);
}

pub fn tryRecordCachedSource(handle: *const anyopaque, row: u64) bool {
    recordCachedSource(handle, row) catch return false;

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

pub fn commitGeneratedSource(handle: *const anyopaque, position: u64, index: u64) Error!void {
    const frame: *const GeneratedRows = @ptrCast(@alignCast(handle));
    const found = frame.lookups[@intCast(position)];
    const result = &frame.results[@intCast(index)];
    const cache = frame.cache;
    cache.generated += 1;

    try cache.putShared(found.name, found.key, result.owned.?);

    result.source = null;
    result.owned = null;
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
