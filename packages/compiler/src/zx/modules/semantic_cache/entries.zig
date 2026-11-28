const std = @import("std");
const Artifact = @import("../artifact/model.zig");
const codec = @import("codec.zig");
const generated = @import("parser_options").generated_parser;
const ABI = @import("project_execution_abi").layouts.@"zig:project_host";
const Probe = if (generated) ABI.CacheProbe else struct { bucket: u64, row: u64 };

pub const Entry = struct {
    dirty: bool = true,
    decoded: bool = false,
    native_admitted: bool = false,
    context_digest: [32]u8,
    result: Artifact.Result,
    pub fn digestView(self: *Entry, comptime Layout: type) Layout {
        return .{
            .entry = @ptrCast(self),
            .source = &self.result.value.source_digest,
            .context = &self.context_digest,
        };
    }
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
    probe: Probe = undefined,
    const NewSlot = struct { entry: *Entry, key: []const u8 };

    fn borrow(handle: *anyopaque) *Pending {
        return @ptrCast(@alignCast(handle));
    }
    pub fn cancel(self: *Pending) void {
        if (self.added) |added| {
            self.allocator.destroy(added.entry);
            self.allocator.free(added.key);
        }
    }
};

pub fn probeCacheSlot(handle: *anyopaque) *const Probe {
    const slot = Pending.borrow(handle);
    const bucket = slot.entries.position(slot.value.?.result.value.path).slot;
    const row: u64 = if (slot.entries.buckets.len == 0) 0 else slot.entries.buckets[bucket];

    slot.probe = .{ .bucket = bucket, .row = row };

    return &slot.probe;
}

pub fn reserveCacheSlot(handle: *anyopaque, previous: u64) std.mem.Allocator.Error!u64 {
    const slot = Pending.borrow(handle);
    const path = slot.value.?.result.value.path;

    return try slot.entries.prepare(slot.allocator, path, @intCast(previous));
}

pub fn stageCacheSlot(handle: *anyopaque) std.mem.Allocator.Error!void {
    const slot = Pending.borrow(handle);
    const key = try slot.allocator.dupe(u8, slot.value.?.result.value.path);

    errdefer slot.allocator.free(key);

    const entry = try slot.allocator.create(Entry);
    slot.added = .{ .entry = entry, .key = key };
}

pub fn appendCacheSlot(handle: *anyopaque, bucket: u64) void {
    const slot = Pending.borrow(handle);
    const added = slot.added.?;

    added.entry.* = slot.value.?;

    slot.entries.append(@intCast(bucket), added.key, added.entry);

    slot.value = null;
    slot.added = null;
}

pub fn replaceCacheSlot(handle: *anyopaque, row: u64) void {
    const slot = Pending.borrow(handle);
    const entry = slot.entries.values.items[@intCast(row)];

    entry.result.deinit();

    entry.* = slot.value.?;
    slot.value = null;
}

pub fn prepareSeed(slot: *Pending) std.mem.Allocator.Error!Probe {
    const found = probeCacheSlot(slot);

    if (found.row != 0) return found.*;

    const position = try reserveCacheSlot(slot, found.bucket);

    try stageCacheSlot(slot);

    return .{ .bucket = position, .row = 0 };
}

pub fn commitSeed(slot: *Pending, prepared: Probe) void {
    if (prepared.row != 0) replaceCacheSlot(slot, prepared.row - 1) else appendCacheSlot(slot, prepared.bucket);
}

pub fn commitPrepared(slot: *Pending, plan: anytype) void {
    if (plan.replacement) |row| {
        replaceCacheSlot(slot, row);
    } else {
        appendCacheSlot(slot, plan.bucket);
    }
}

fn install(allocator: std.mem.Allocator, entries: *Map, value: Entry) std.mem.Allocator.Error!void {
    var slot: Pending = .{ .allocator = allocator, .entries = entries, .value = value };

    errdefer slot.cancel();

    if (comptime generated) {
        const entry = @import("generated_semantic_cache_install_entry");
        const input: std.meta.Child(entry.Input) = .{ .slot = @ptrCast(&slot) };
        var buffer: [128]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);
        const plan = try entry.executeIn(scratch.allocator(), &input);

        commitPrepared(&slot, plan);

        return;
    }

    commitSeed(&slot, try prepareSeed(&slot));
}
