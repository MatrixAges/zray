const std = @import("std");
const zx = @import("zx");
const parser = @import("../frontend/parse.zig");
const probe = @import("parse_cache/probe.zig");
const retention = @import("cache_retention.zig");
const Index = @import("source_index/growing.zig").Map(*Entry);
const Self = @This();
pub const ModuleResult = parser.ModuleResult;
pub const indexed_enabled = @import("../frontend/module_result.zig").indexed_enabled;
const generated = @import("parser_options").generated_parser;
const ABI = if (generated) @import("project_execution_abi").layouts.@"zig:project_host" else void;
const Native = if (generated) @import("project_execution_abi").native.@"zig:project_host" else void;
const Digest = [zx.Sha256.digest_length]u8;

const Entry = struct {
    digest: Digest,
    result: ModuleResult,
    text: ?[]const u8,
    mark: u64 = 0,
    fn init(digest: Digest, result: ModuleResult) Entry {
        return .{ .digest = digest, .result = result, .text = result.text() };
    }
};

const Transient = struct { result: ModuleResult, retention: retention.Retention };

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
clock: retention.Clock = .{},

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
    self.clock.published = 0;
}

/// Drops parses outside the latest input set. The caller must have released all outstanding views.
pub fn retainPaths(self: *Self, paths: anytype) void {
    var kept: usize = 0;

    for (self.entries.keys.items, self.entries.values.items) |path, entry| {
        if (paths.contains(path)) {
            self.entries.keys.items[kept] = path;
            self.entries.values.items[kept] = entry;
            kept += 1;
        } else {
            entry.result.deinit();
            self.allocator.destroy(entry);
            self.allocator.free(path);
        }
    }

    if (kept == self.entries.keys.items.len) return;

    if (kept == 0) {
        self.entries.deinit(self.allocator);

        self.entries = .empty;
    } else self.entries.truncate(kept);
}

pub fn reserveAnalysis(self: *Self) std.mem.Allocator.Error!void {
    try self.replaced.ensureUnusedCapacity(self.allocator, self.transient.items.len);
}

pub fn keepAnalysis(self: *Self) void {
    self.clock.publish();
    self.retire(true);
}

pub fn endRequest(self: *Self) void {
    self.retire(false);
}

fn retire(self: *Self, published: bool) void {
    if (self.transient.items.len == 0) return;

    if (comptime generated) {
        const rule = @import("generated_parse_cache_retire");
        const memory = zx.memory;

        const marks = if (published)
            memory.borrowNestedColumn(bool, &.{ "retention", "keep_on_publish" }, self.transient.items)
        else
            memory.borrowNestedColumn(bool, &.{ "retention", "keep_on_abort" }, self.transient.items);

        var target: memory.WriteColumn = .{
            .items = @ptrCast(&self.retained_capacity),
            .count = 1,
            .stride = @sizeOf(usize),
            .width = @sizeOf(usize),
        };

        const input: std.meta.Child(rule.Input) = .{
            .cache = @ptrCast(self),
            .marks = @ptrCast(&marks),
            .count = self.transient.items.len,
            .capacity = self.retained_capacity,
            .target = @ptrCast(&target),
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
        self.transient.clearRetainingCapacity();

        return;
    }

    for (self.transient.items) |*version| {
        if (version.retention.keep(published)) {
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
    const results = try self.allocator.alloc(?*Entry, count);

    defer self.allocator.free(results);

    const workers = @min(count, parallel.width());
    const staging = try self.allocator.alloc(std.heap.ArenaAllocator, workers);

    defer self.allocator.free(staging);
    defer for (staging) |*arena| arena.deinit();
    @memset(results, null);
    @memset(staging, .init(std.heap.smp_allocator));

    const output: BatchOutput = binding: {
        const views = outputs orelse break :binding .none;

        break :binding if (Output == Entry) .{ .entries = views } else .{ .modules = views };
    };

    if (comptime generated) {
        const memory = zx.memory;
        const registered = comptime @hasField(@TypeOf(requests), "paths");
        const paths = if (registered) memory.borrowTextSlice(requests.paths) else memory.borrowTextColumn("path", requests.items);
        const texts = memory.borrowTextColumn("source", if (registered) requests.sources else requests.items);

        var work: ParseWork = .{
            .cache = self,
            .paths = &paths,
            .texts = &texts,
            .results = results,
            .output = output,
            .staging = staging,
        };

        parallel.spread(ParseWork, &work, ParseWork.run, workers);

        return self.publishPrefetched(&paths, results, output, work.failed.load(.monotonic));
    }

    const Seed = struct {
        cache: *const Self,
        requests: @TypeOf(requests),
        results: []?*Entry,
        output: BatchOutput,
        staging: []std.heap.ArenaAllocator,
        batch_size: usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        fn run(work: *@This(), participant: usize) void {
            var scratch = zx.Arena.init(std.heap.page_allocator);

            defer scratch.deinit();

            const staged = work.staging[participant].allocator();

            while (!work.failed.load(.monotonic)) {
                const first = work.next.fetchAdd(work.batch_size, .monotonic);

                if (first >= work.results.len) return;

                const end = first + @min(work.batch_size, work.results.len - first);

                for (first..end) |index| {
                    const request = work.requests.at(index);
                    const existing = work.cache.entries.get(request.path);
                    var digest: Digest = undefined;

                    if (lookup(existing, request.source, false, &digest) == .Reuse) {
                        if (work.output != .none) work.output.bind(index, existing.?);
                    } else work.results[index] = stageResult(staged, &scratch, request, digest) catch {
                        work.failed.store(true, .monotonic);

                        return;
                    };
                }
            }
        }
    };

    const batch_size = @min(max_parse_batch, @max(1, count / workers));

    var work: Seed = .{
        .cache = self,
        .requests = requests,
        .results = results,
        .output = output,
        .staging = staging,
        .batch_size = batch_size,
    };

    parallel.spread(Seed, &work, Seed.run, workers);

    var kept: usize = 0;

    errdefer for (results[kept..]) |result| if (result) |value| value.result.deinit();

    for (results, 0..) |result, index| {
        if (result) |value| {
            const path = requests.at(index).path;
            const entry = try self.adopt(path, self.entries.probe(path), value);

            if (output != .none) output.bind(index, entry);
        }

        kept += 1;
    }

    if (work.failed.load(.monotonic)) return error.OutOfMemory;
}

const BatchOutput = union(enum) {
    none,
    entries: []*const Entry,
    modules: []*const ModuleResult,
    fn bind(self: BatchOutput, index: usize, entry: *const Entry) void {
        switch (self) {
            .none => unreachable,
            .entries => |views| views[index] = entry,
            .modules => |views| views[index] = &entry.result,
        }
    }
};

const ParseWork = struct {
    cache: *const Self,
    paths: *const zx.memory.TextColumn,
    texts: *const zx.memory.TextColumn,
    results: []?*Entry,
    output: BatchOutput,
    staging: []std.heap.ArenaAllocator,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    fn run(work: *ParseWork, participant: usize) void {
        const rule = @import("generated_parse_cache_worker");
        const memory = zx.memory;
        var scratch = zx.Arena.init(std.heap.page_allocator);

        defer scratch.deinit();

        const worker: ParseWorker = .{ .work = work, .arena = &scratch, .staged = work.staging[participant].allocator() };
        const entries = &work.cache.entries;
        const cached_text = memory.borrowReferenceColumn("text", entries.values.items);
        const cached_digest = memory.borrowReferenceColumn("digest", entries.values.items);
        var hits: [max_parse_batch]u64 = undefined;
        var digests: [max_parse_batch]Digest = undefined;
        var hit_rows: []u64 = &hits;
        var digest_bytes = std.mem.sliceAsBytes(digests[0..]);
        const input_type = std.meta.Child(rule.Input);
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const width = @min(max_parse_batch, @max(1, work.results.len / work.staging.len));

        const cache_view: std.meta.Child(@FieldType(input_type, "cache")) = .{
            .keys = entries.keys.items,
            .buckets = @ptrCast(&entries.buckets),
            .capacity = entries.buckets.len,
            .texts = @ptrCast(&cached_text),
            .digests = @ptrCast(&cached_digest),
        };

        const sources_view: std.meta.Child(@FieldType(input_type, "sources")) = .{
            .paths = @ptrCast(work.paths),
            .texts = @ptrCast(work.texts),
        };

        const buffers_view: std.meta.Child(@FieldType(input_type, "buffers")) = .{
            .hits = @ptrCast(&hit_rows),
            .hit_rows = hit_rows,
            .digests = @ptrCast(&digest_bytes),
            .digest_bytes = digest_bytes,
            .digest_width = @sizeOf(Digest),
        };

        while (!work.failed.load(.monotonic)) {
            const first = work.next.fetchAdd(width, .monotonic);

            if (first >= work.results.len) return;

            const range_view: std.meta.Child(@FieldType(input_type, "range")) = .{ .first = first, .count = @min(width, work.results.len - first) };

            const input: input_type = .{
                .worker = @ptrCast(&worker),
                .cache = &cache_view,
                .sources = &sources_view,
                .buffers = &buffers_view,
                .range = &range_view,
                .has_output = work.output != .none,
            };

            const ok = rule.executeIn(empty.allocator(), &input) catch unreachable;

            if (!ok) {
                work.failed.store(true, .monotonic);

                return;
            }
        }
    }
};

const ParseWorker = struct {
    work: *ParseWork,
    arena: *zx.Arena,
    staged: std.mem.Allocator,
    fn borrow(handle: *const anyopaque) *const ParseWorker {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn bindParseWorkerHit(handle: *const anyopaque, index: u64, hit: u64) void {
    const work = ParseWorker.borrow(handle).work;

    work.output.bind(@intCast(index), work.cache.entries.values.items[@intCast(hit)]);
}

pub fn stageParseWorkerResult(handle: *const anyopaque, index: u64, source: []const u8, path: []const u8, digest: []const u8) bool {
    const worker = ParseWorker.borrow(handle);
    const entry = stageResult(worker.staged, worker.arena, .{ .path = path, .source = source }, digest[0..@sizeOf(Digest)].*) catch return false;

    worker.work.results[@intCast(index)] = entry;

    return true;
}

fn stageResult(staged: std.mem.Allocator, scratch: *zx.Arena, request: Request, digest: Digest) std.mem.Allocator.Error!*Entry {
    const entry = try staged.create(Entry);
    const result = try parser.parseAnalysisModuleIn(std.heap.smp_allocator, scratch, request.source, request.path);
    entry.* = .init(digest, result);

    return entry;
}

const Batch = struct {
    adoption: Adoption,
    output: BatchOutput,
    prefetched: if (generated) ABI.PrefetchedParse else void = undefined,
    fn borrow(handle: *anyopaque) *Batch {
        return @ptrCast(@alignCast(handle));
    }
};

fn publishPrefetched(self: *Self, paths: *const zx.memory.TextColumn, results: []const ?*Entry, output: BatchOutput, worker_failed: bool) std.mem.Allocator.Error!void {
    const rule = @import("generated_parse_cache_publish");
    var batch: Batch = .{ .adoption = .{ .cache = self, .path = undefined, .found = undefined }, .output = output };

    const input: std.meta.Child(rule.Input) = .{
        .batch = @ptrCast(&batch),
        .paths = @ptrCast(paths),
        .results = @ptrCast(results),
        .has_output = output != .none,
        .worker_failed = worker_failed,
    };

    var arena = std.heap.ArenaAllocator.init(self.allocator);

    defer arena.deinit();

    var buffer: [4096]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const ok = rule.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (!ok) return error.OutOfMemory;
}

pub fn preparePrefetchedParse(handle: *anyopaque, path: []const u8) Native.preparePrefetchedParse.Output {
    const batch = Batch.borrow(handle);

    batch.adoption.path = path;
    batch.adoption.found = batch.adoption.cache.entries.probe(path);

    batch.prefetched = .{
        .adoption = @ptrCast(&batch.adoption),
        .existing = if (batch.adoption.found.existing) |entry| @ptrCast(entry) else null,
    };

    return &batch.prefetched;
}

pub fn bindPrefetchedParse(handle: *anyopaque, index: u64, handle_entry: *anyopaque) void {
    const batch = Batch.borrow(handle);
    const entry: *const Entry = @ptrCast(@alignCast(handle_entry));

    batch.output.bind(@intCast(index), entry);
}

pub fn discardStagedParse(handle: *anyopaque) void {
    const entry: *Entry = @ptrCast(@alignCast(handle));

    entry.result.deinit();
}

const Adoption = struct {
    cache: *Self,
    path: []const u8,
    found: Index.Slot,
    fn borrow(handle: *const anyopaque) *const Adoption {
        return @ptrCast(@alignCast(handle));
    }
    fn replace(self: *const Adoption, entry: *Entry, value: *const Entry) std.mem.Allocator.Error!void {
        try self.cache.replace(entry);

        entry.* = value.*;
        entry.mark = self.cache.clock.current;
        self.cache.parsed += 1;
    }

    fn insert(self: *const Adoption, value: *const Entry) std.mem.Allocator.Error!*Entry {
        const cache = self.cache;
        const slot = try cache.entries.prepare(cache.allocator, self.path, self.found.position);
        const key = try cache.allocator.dupe(u8, self.path);

        errdefer cache.allocator.free(key);

        const entry = try cache.allocator.create(Entry);
        entry.* = value.*;
        entry.mark = cache.clock.current;

        cache.entries.append(slot, key, entry);

        cache.parsed += 1;

        return entry;
    }
};

pub fn insertParseEntry(handle: *const anyopaque, candidate: *anyopaque) Native.insertParseEntry.Output {
    const entry = Adoption.borrow(handle).insert(@ptrCast(@alignCast(candidate))) catch return null;

    return @ptrCast(entry);
}

pub fn replaceParseEntry(handle: *const anyopaque, existing: *anyopaque, candidate: *anyopaque) bool {
    Adoption.borrow(handle).replace(@ptrCast(@alignCast(existing)), @ptrCast(@alignCast(candidate))) catch return false;

    return true;
}

fn adopt(self: *Self, path: []const u8, found: Index.Slot, value: *Entry) std.mem.Allocator.Error!*Entry {
    const adoption: Adoption = .{ .cache = self, .path = path, .found = found };

    if (comptime generated) {
        const rule = @import("generated_parse_cache_adopt");

        const input: std.meta.Child(rule.Input) = .{
            .adoption = @ptrCast(&adoption),
            .existing = if (found.existing) |entry| @ptrCast(entry) else null,
            .candidate = @ptrCast(value),
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});
        const entry = (rule.executeIn(scratch.allocator(), &input) catch unreachable) orelse return error.OutOfMemory;

        return @ptrCast(@alignCast(entry));
    }

    if (found.existing) |entry| {
        try adoption.replace(entry, value);

        return entry;
    }

    return adoption.insert(value);
}

const Replacement = struct {
    cache: *Self,
    entry: *const Entry,
    fn discard(self: *const Replacement) void {
        var owned = self.entry.result;

        owned.deinit();
    }
    fn keep(self: *const Replacement) std.mem.Allocator.Error!void {
        try self.cache.replaced.append(self.cache.allocator, self.entry.result);

        self.cache.retained_capacity += self.entry.result.queryCapacity();
    }
    fn queue(self: *const Replacement, plan: retention.Retention) std.mem.Allocator.Error!void {
        const cache = self.cache;

        if (plan.keep_on_abort) try cache.replaced.ensureUnusedCapacity(cache.allocator, cache.transient.items.len + 1);
        try cache.transient.append(cache.allocator, .{ .result = self.entry.result, .retention = plan });
    }
};

fn replace(self: *Self, entry: *const Entry) std.mem.Allocator.Error!void {
    const replacement: Replacement = .{ .cache = self, .entry = entry };

    if (comptime generated) {
        const rule = @import("generated_parse_cache_replacement");

        const input: std.meta.Child(rule.Input) = .{
            .keeps_replaced = self.keeps_replaced,
            .transactional = self.transactional,
            .mark = entry.mark,
            .published = self.clock.published,
        };

        var buffer: [128]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);
        const decision = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

        return switch (decision.action) {
            .Discard => replacement.discard(),
            .Keep => replacement.keep(),
            .Queue => replacement.queue(.{
                .keep_on_publish = decision.keep_on_publish,
                .keep_on_abort = decision.keep_on_abort,
            }),
        };
    }

    if (!self.keeps_replaced) return replacement.discard();
    if (!self.transactional) return replacement.keep();

    return replacement.queue(self.clock.classify(entry.mark));
}

pub fn retainPendingParse(handle: *anyopaque, row: u64) u64 {
    const self: *Self = @ptrCast(@alignCast(handle));
    const result = &self.transient.items[@intCast(row)].result;

    self.replaced.appendAssumeCapacity(result.*);

    return result.queryCapacity();
}

pub fn discardPendingParse(handle: *anyopaque, row: u64) void {
    const self: *Self = @ptrCast(@alignCast(handle));

    self.transient.items[@intCast(row)].result.deinit();
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
        try parser.parseAnalysisModule(self.allocator, source, path));

    errdefer prepared.result.deinit();

    return self.adopt(path, found, &prepared);
}

fn lookup(entry: ?*const Entry, source: []const u8, native: bool, digest: *[32]u8) probe.Action {
    const kept = entry orelse return probe.run(source, null, null, native, false, digest);

    return probe.run(source, kept.text, &kept.digest, native, kept.result == .indexed, digest);
}
