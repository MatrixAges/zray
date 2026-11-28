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
    pub fn digestView(self: *const Entry, comptime Layout: type) Layout {
        return .{
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
    install: if (generated) ABI.CacheInstall else void = undefined,
    const NewSlot = struct { entry: *Entry, key: []const u8, bucket: usize };

    pub fn installView(self: *const Pending, comptime Layout: type, key: []const u8) Layout {
        return .{
            .key = key,
            .keys = self.entries.keys.items,
            .buckets = self.entries.buckets,
        };
    }

    pub fn cancel(self: *Pending) void {
        if (self.added) |added| {
            self.allocator.destroy(added.entry);
            self.allocator.free(added.key);
        }
    }

    pub fn stage(self: *Pending, previous: u64) std.mem.Allocator.Error!void {
        const path = self.value.?.result.value.path;
        const bucket = try self.entries.prepare(self.allocator, path, @intCast(previous));
        const key = try self.allocator.dupe(u8, path);

        errdefer self.allocator.free(key);

        const entry = try self.allocator.create(Entry);
        self.added = .{ .entry = entry, .key = key, .bucket = bucket };
    }
    pub fn commit(self: *Pending, replacement: ?u64) void {
        if (replacement) |row| {
            const entry = self.entries.values.items[@intCast(row)];

            entry.result.deinit();

            entry.* = self.value.?;
        } else {
            const added = self.added.?;

            added.entry.* = self.value.?;

            self.entries.append(added.bucket, added.key, added.entry);

            self.added = null;
        }

        self.value = null;
    }
};

pub fn prepareSeed(slot: *Pending) std.mem.Allocator.Error!?u64 {
    const found = slot.entries.position(slot.value.?.result.value.path);

    if (found.row) |row| return row;

    try slot.stage(found.slot);

    return null;
}

fn install(allocator: std.mem.Allocator, entries: *Map, value: Entry) std.mem.Allocator.Error!void {
    var slot: Pending = .{ .allocator = allocator, .entries = entries, .value = value };

    errdefer slot.cancel();

    if (comptime generated) {
        const entry = @import("generated_semantic_cache_install_entry");
        const input = slot.installView(std.meta.Child(entry.Input), value.result.value.path);
        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        var buffer: [128]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

        const plan = entry.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        if (plan.replacement == null) try slot.stage(plan.bucket);

        slot.commit(plan.replacement);

        return;
    }

    slot.commit(try prepareSeed(&slot));
}
