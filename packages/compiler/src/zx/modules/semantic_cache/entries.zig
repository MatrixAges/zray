const std = @import("std");
const Artifact = @import("../artifact/model.zig");
const codec = @import("codec.zig");
const generated = @import("parser_options").generated_parser;
const ABI = @import("project_execution_abi").layouts.@"zig:project_host";

pub const Entry = struct {
    dirty: bool = true,
    decoded: bool = false,
    native_admitted: bool = false,
    context_digest: [32]u8,
    result: Artifact.Result,
};

pub const Map = @import("../source_index/growing.zig").Map(*Entry);

pub fn deinit(allocator: std.mem.Allocator, entries: *Map) void {
    for (entries.keys.items, entries.values.items) |key, entry| {
        entry.result.deinit();
        allocator.destroy(entry);
        allocator.free(key);
    }

    entries.deinit(allocator);
}

pub fn get(entries: *const Map, path: []const u8, source_digest: [32]u8, context_digest: [32]u8) ?*const Artifact.Module {
    const entry = find(entries, path, &source_digest, &context_digest) orelse return null;

    return &entry.result.value;
}

pub fn find(entries: *const Map, path: []const u8, source_digest: *const [32]u8, context_digest: *const [32]u8) ?*Entry {
    const entry = entries.get(path) orelse return null;

    if (!std.mem.eql(u8, &entry.result.value.source_digest, source_digest)) return null;
    if (!std.mem.eql(u8, &entry.context_digest, context_digest)) return null;

    return entry;
}

pub fn openCachedEntry(handle: *const anyopaque, path: []const u8) ?*const ABI.CacheEntry {
    const entries: *const Map = @ptrCast(@alignCast(handle));

    return @ptrCast(entries.get(path));
}

pub fn cachedSourceDigest(handle: *const anyopaque) []const u8 {
    const entry: *const Entry = @ptrCast(@alignCast(handle));

    return &entry.result.value.source_digest;
}

pub fn cachedContextDigest(handle: *const anyopaque) []const u8 {
    const entry: *const Entry = @ptrCast(@alignCast(handle));

    return &entry.context_digest;
}

pub fn put(allocator: std.mem.Allocator, entries: *Map, result: Artifact.Result, context_digest: [32]u8) std.mem.Allocator.Error!void {
    try install(allocator, entries, .{ .result = result, .context_digest = context_digest });
}

pub fn load(allocator: std.mem.Allocator, entries: *Map, bytes: []const u8, compiler_digest: [32]u8, expected: []const u8) codec.Error!void {
    var decoded = try codec.decodeForPath(allocator, bytes, compiler_digest, expected);

    errdefer decoded.result.deinit();

    try install(allocator, entries, .{
        .dirty = false,
        .decoded = true,
        .result = decoded.result,
        .context_digest = decoded.context_digest,
    });
}

pub const Pending = struct {
    allocator: std.mem.Allocator,
    entries: *Map,
    value: ?Entry = null,
    added: ?NewSlot = null,
    const NewSlot = struct { entry: *Entry, key: []const u8 };

    fn borrow(handle: *const anyopaque) *Pending {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    pub fn cancel(self: *Pending) void {
        if (self.added) |added| {
            self.allocator.destroy(added.entry);
            self.allocator.free(added.key);
        }
    }
};

pub fn probeCacheSlot(handle: *const anyopaque) u64 {
    const slot = Pending.borrow(handle);

    return slot.entries.position(slot.value.?.result.value.path).slot;
}

pub fn readCacheBucket(handle: *const anyopaque, bucket: u64) u64 {
    const entries = Pending.borrow(handle).entries;

    return if (entries.buckets.len == 0) 0 else entries.buckets[@intCast(bucket)];
}

pub fn reserveCacheSlot(handle: *const anyopaque, previous: u64) std.mem.Allocator.Error!u64 {
    const slot = Pending.borrow(handle);
    const path = slot.value.?.result.value.path;

    return try slot.entries.prepare(slot.allocator, path, @intCast(previous));
}

pub fn stageCacheSlot(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const slot = Pending.borrow(handle);
    const key = try slot.allocator.dupe(u8, slot.value.?.result.value.path);

    errdefer slot.allocator.free(key);

    const entry = try slot.allocator.create(Entry);
    slot.added = .{ .entry = entry, .key = key };
}

pub fn appendCacheSlot(handle: *const anyopaque, bucket: u64) void {
    const slot = Pending.borrow(handle);
    const added = slot.added.?;

    added.entry.* = slot.value.?;

    slot.entries.append(@intCast(bucket), added.key, added.entry);

    slot.value = null;
    slot.added = null;
}

pub fn replaceCacheSlot(handle: *const anyopaque, row: u64) void {
    const slot = Pending.borrow(handle);
    const entry = slot.entries.values.items[@intCast(row)];

    entry.result.deinit();

    entry.* = slot.value.?;
    slot.value = null;
}

pub fn prepareSeed(slot: *Pending) std.mem.Allocator.Error!u64 {
    const found = probeCacheSlot(slot);

    if (readCacheBucket(slot, found) != 0) return found;

    const position = try reserveCacheSlot(slot, found);

    try stageCacheSlot(slot);

    return position;
}

pub fn commitSeed(slot: *Pending, bucket: u64) void {
    const row = readCacheBucket(slot, bucket);

    if (row != 0) replaceCacheSlot(slot, row - 1) else appendCacheSlot(slot, bucket);
}

fn install(allocator: std.mem.Allocator, entries: *Map, value: Entry) std.mem.Allocator.Error!void {
    var slot: Pending = .{ .allocator = allocator, .entries = entries, .value = value };

    errdefer slot.cancel();

    if (comptime generated) {
        const entry = @import("generated_semantic_cache_install_entry");
        const input: std.meta.Child(entry.Input) = .{ .slot = @ptrCast(&slot) };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return entry.executeIn(empty.allocator(), &input);
    }

    commitSeed(&slot, try prepareSeed(&slot));
}
