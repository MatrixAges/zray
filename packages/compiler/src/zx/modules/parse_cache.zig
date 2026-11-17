const std = @import("std");
const zx = @import("zx");
const parser = @import("../frontend/parse.zig");
const probe = @import("parse_cache/probe.zig");
const Index = @import("source_index/growing.zig").Map(*Entry);
const Self = @This();
pub const ModuleResult = parser.ModuleResult;
pub const indexed_enabled = @import("../frontend/module_result.zig").indexed_enabled;
const Digest = [zx.Sha256.digest_length]u8;

const Entry = struct {
    digest: Digest,
    result: ModuleResult,
    text: ?[]const u8,
    retained: bool = false,
    fn init(digest: Digest, result: ModuleResult) Entry {
        return .{ .digest = digest, .result = result, .text = result.text() };
    }
};

const Transient = struct { result: ModuleResult, retained: bool };

allocator: std.mem.Allocator,
entries: Index = .empty,
parsed: usize = 0,
reused: usize = 0,
/// Keeps replaced results until `release` instead of freeing them, for analyses that still point into them.
keeps_replaced: bool = false,
/// A resident analysis pins the parses it publishes and drops replacements used only by a failed request.
transactional: bool = false,
replaced: std.ArrayList(ModuleResult) = .empty,
transient: std.ArrayList(Transient) = .empty,
retained_capacity: usize = 0,
pub fn deinit(self: *Self) void {
    self.endRequest();
    self.release();
    self.replaced.deinit(self.allocator);
    self.transient.deinit(self.allocator);

    for (self.entries.keys.items, self.entries.values.items) |key, entry| {
        entry.result.deinit();
        self.allocator.destroy(entry);
        self.allocator.free(key);
    }

    self.entries.deinit(self.allocator);

    self.* = undefined;
}

/// Frees the results replaced since the last call.
pub fn release(self: *Self) void {
    for (self.replaced.items) |*result| result.deinit();

    self.replaced.clearRetainingCapacity();

    self.retained_capacity = 0;

    for (self.entries.values.items) |entry| entry.retained = false;
}

pub fn reserveAnalysis(self: *Self) std.mem.Allocator.Error!void {
    try self.replaced.ensureUnusedCapacity(self.allocator, self.transient.items.len);
}

pub fn keepAnalysis(self: *Self) void {
    for (self.entries.values.items) |entry| entry.retained = true;

    self.retire(true);
}

pub fn endRequest(self: *Self) void {
    self.retire(false);
}

fn retire(self: *Self, published: bool) void {
    for (self.transient.items) |*version| {
        if (published or version.retained) {
            self.replaced.appendAssumeCapacity(version.result);

            self.retained_capacity += version.result.queryCapacity();
        } else version.result.deinit();
    }

    self.transient.clearRetainingCapacity();
}

pub fn currentCapacity(self: *const Self) usize {
    var capacity: usize = 0;

    for (self.entries.values.items) |entry| capacity += entry.result.queryCapacity();

    return capacity;
}

/// The digest of the source last parsed for `path`.
pub fn sourceDigest(self: *const Self, path: []const u8) ?[32]u8 {
    const entry = self.entries.get(path) orelse return null;

    return entry.digest;
}

pub fn get(self: *Self, source: []const u8, path: []const u8) std.mem.Allocator.Error!*const parser.Result {
    const entry = try self.getEntry(true, source, path);

    return &entry.result.native;
}

pub fn getModule(self: *Self, source: []const u8, path: []const u8) std.mem.Allocator.Error!*const ModuleResult {
    const entry = try self.getEntry(false, source, path);

    return &entry.result;
}

pub const Version = struct { result: *const ModuleResult, digest: [32]u8 };

/// A freshly verified batch, in input order. Borrow until the next cache mutation.
pub const Prefetched = struct {
    cache: ?*Self = null,
    sources: []const Source = &.{},
    paths: []const []const u8 = &.{},
    entries: []const *const Entry = &.{},
    pub fn module(self: Prefetched, row: usize) *const ModuleResult {
        return &self.entries[row].result;
    }

    pub fn at(self: Prefetched, row: usize) Version {
        const entry = self.entries[row];

        return .{ .result = &entry.result, .digest = entry.digest };
    }
    pub fn deinit(self: *Prefetched, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);

        self.* = .{};
    }
};

pub fn getModuleVersion(self: *Self, source: []const u8, path: []const u8) std.mem.Allocator.Error!Version {
    const entry = try self.getEntry(false, source, path);

    return .{ .result = &entry.result, .digest = entry.digest };
}

pub const Request = struct { source: []const u8, path: []const u8 };
const Source = @import("project.zig").Source;
const max_parse_batch = 16;

const Requests = struct {
    items: []const Request,
    fn at(self: Requests, row: usize) Request {
        return self.items[row];
    }
};

const Registered = struct {
    sources: []const Source,
    paths: []const []const u8,
    fn at(self: Registered, row: usize) Request {
        return .{ .source = self.sources[row].source, .path = self.paths[row] };
    }
};

/// Parses on all cores the modules `getModule` has no current result for, so a later walk over them only reads. Each
/// result keeps its own arena over the thread-safe page-level allocator, whichever thread parsed it.
pub fn prefetch(self: *Self, requests: []const Request) std.mem.Allocator.Error!void {
    return self.prefetchInto(Requests{ .items = requests }, requests.len, ModuleResult, null);
}

/// Fills the result for each request in the same order. Paths must be distinct. The views remain valid under
/// the same conditions as `getModule` results.
pub fn prefetchModules(self: *Self, requests: []const Request, modules: []*const ModuleResult) std.mem.Allocator.Error!void {
    std.debug.assert(requests.len == modules.len);

    return self.prefetchInto(Requests{ .items = requests }, requests.len, ModuleResult, modules);
}

/// The source and canonical path columns are borrowed until all workers finish.
pub fn prefetchRegistered(self: *Self, allocator: std.mem.Allocator, sources: []const Source, paths: []const []const u8) std.mem.Allocator.Error!Prefetched {
    std.debug.assert(sources.len == paths.len);

    const entries = try allocator.alloc(*const Entry, sources.len);

    errdefer allocator.free(entries);

    try self.prefetchInto(Registered{ .sources = sources, .paths = paths }, sources.len, Entry, entries);

    return .{ .cache = self, .sources = sources, .paths = paths, .entries = entries };
}

fn prefetchInto(self: *Self, requests: anytype, count: usize, comptime Output: type, outputs: ?[]*const Output) std.mem.Allocator.Error!void {
    if (count == 0) return;

    const parallel = zx.parallel;

    const Prefetch = struct {
        cache: *const Self,
        requests: @TypeOf(requests),
        results: []?*Entry,
        outputs: ?[]*const Output,
        staging: []std.heap.ArenaAllocator,
        batch_size: usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        fn run(work: *@This(), participant: usize) void {
            var scratch = zx.Arena.init(std.heap.page_allocator);

            defer scratch.deinit();

            const staged = work.staging[participant].allocator();
            var hits: [max_parse_batch]u64 = undefined;
            var digests: [max_parse_batch]Digest = undefined;
            var digest_scratch: [max_parse_batch * @sizeOf(Digest)]u8 = undefined;

            while (!work.failed.load(.monotonic)) {
                const first = work.next.fetchAdd(work.batch_size, .monotonic);

                if (first >= work.results.len) return;

                const end = first + @min(work.batch_size, work.results.len - first);

                if (comptime indexed_enabled) {
                    const batch_count = end - first;

                    @import("parse_cache/batch.zig").classify(&work.cache.entries, work.requests, first, hits[0..batch_count], digests[0..batch_count], &digest_scratch) catch {
                        work.failed.store(true, .monotonic);

                        return;
                    };
                }

                for (first..end, 0..) |index, offset| {
                    var digest: Digest = undefined;

                    const found: ?*Entry = if (comptime indexed_enabled) hit: {
                        const row = hits[offset];

                        if (row != 0) break :hit work.cache.entries.values.items[@intCast(row - 1)];

                        digest = digests[offset];

                        break :hit null;
                    } else seed: {
                        const request = work.requests.at(index);
                        const existing = work.cache.entries.get(request.path);

                        break :seed if (lookup(existing, request.source, false, &digest) == .Reuse) existing else null;
                    };

                    if (found) |entry| {
                        if (work.outputs) |views| views[index] = if (Output == Entry) entry else &entry.result;

                        continue;
                    }

                    work.results[index] = parse(staged, &scratch, work.requests.at(index), digest) catch {
                        work.failed.store(true, .monotonic);

                        return;
                    };
                }
            }
        }
        fn parse(staged: std.mem.Allocator, scratch: *zx.Arena, request: Request, digest: Digest) std.mem.Allocator.Error!*Entry {
            const entry = try staged.create(Entry);
            const result = try parser.parseModuleIn(std.heap.smp_allocator, scratch, request.source, request.path);
            entry.* = .init(digest, result);

            return entry;
        }
    };

    const results = try self.allocator.alloc(?*Entry, count);

    defer self.allocator.free(results);

    const workers = @min(count, parallel.width());
    const staging = try self.allocator.alloc(std.heap.ArenaAllocator, workers);

    defer self.allocator.free(staging);
    defer for (staging) |*arena| arena.deinit();
    @memset(results, null);
    @memset(staging, .init(std.heap.smp_allocator));

    const batch_size = @min(max_parse_batch, @max(1, count / workers));
    var work = Prefetch{ .cache = self, .requests = requests, .results = results, .outputs = outputs, .staging = staging, .batch_size = batch_size };

    parallel.spread(Prefetch, &work, Prefetch.run, workers);

    var kept: usize = 0;

    errdefer for (results[kept..]) |result| if (result) |value| value.result.deinit();

    for (results, 0..) |result, index| {
        if (result) |value| {
            const path = requests.at(index).path;
            const entry = try self.adopt(path, self.entries.probe(path), value);

            if (outputs) |views| views[index] = if (Output == Entry) entry else &entry.result;
        }

        kept += 1;
    }

    if (work.failed.load(.monotonic)) return error.OutOfMemory;
}

fn adopt(self: *Self, path: []const u8, found: Index.Slot, value: *const Entry) std.mem.Allocator.Error!*Entry {
    if (found.existing) |entry| {
        try self.replace(entry);

        entry.* = value.*;
        self.parsed += 1;

        return entry;
    }

    const slot = if (try self.entries.reserve(self.allocator)) self.entries.probe(path).position else found.position;
    const key = try self.allocator.dupe(u8, path);

    errdefer self.allocator.free(key);

    const entry = try self.allocator.create(Entry);

    errdefer self.allocator.destroy(entry);

    entry.* = value.*;

    self.entries.append(slot, key, entry);

    self.parsed += 1;

    return entry;
}

fn replace(self: *Self, entry: *const Entry) std.mem.Allocator.Error!void {
    if (!self.keeps_replaced) {
        var owned = entry.result;

        return owned.deinit();
    }

    if (!self.transactional) {
        try self.replaced.append(self.allocator, entry.result);

        self.retained_capacity += entry.result.queryCapacity();

        return;
    }

    if (entry.retained) try self.replaced.ensureUnusedCapacity(self.allocator, self.transient.items.len + 1);
    try self.transient.append(self.allocator, .{ .result = entry.result, .retained = entry.retained });
}

fn getEntry(self: *Self, comptime native: bool, source: []const u8, path: []const u8) std.mem.Allocator.Error!*Entry {
    var digest: [32]u8 = undefined;
    const found = self.entries.probe(path);

    switch (lookup(found.existing, source, native, &digest)) {
        .Reuse => {
            self.reused += 1;

            return found.existing.?;
        },
        .Upgrade => digest = found.existing.?.digest,
        .Parse => {},
    }

    var prepared = Entry.init(digest, if (native)
        .{ .native = try parser.parse(self.allocator, source, path) }
    else
        try parser.parseModule(self.allocator, source, path));

    errdefer prepared.result.deinit();

    return self.adopt(path, found, &prepared);
}

fn lookup(entry: ?*const Entry, source: []const u8, native: bool, digest: *[32]u8) probe.Action {
    const kept = entry orelse return probe.run(source, null, null, native, false, digest);

    return probe.run(source, kept.text, &kept.digest, native, kept.result == .indexed, digest);
}
