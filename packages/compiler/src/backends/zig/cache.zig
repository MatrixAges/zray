const std = @import("std");
const Storage = @import("cache/storage.zig");
const policy = @import("cache/policy.zig");
const generated_parser = @import("parser_options").generated_parser;
const zx = @import("zx");
const memory = zx.memory;
const Self = @This();
const Owner = enum(u8) { cache, shared };
const Entry = struct { key: [32]u8, source: []u8, pending: ?usize = null, owner: Owner = .cache };
const Memo = @import("genz").zx.function_analysis.Uniqueness.Memo;
const Index = @import("frontend").SourceIndex(Entry);

allocator: std.mem.Allocator,
entries: Index = .empty,
storage: ?Storage = null,
generated: usize = 0,
reused: usize = 0,
loaded: usize = 0,
written: usize = 0,
discarded: usize = 0,
io_errors: usize = 0,
last_io_error: ?anyerror = null,
/// Keeps the uniqueness memo in `memo` across generations instead of reading and writing it for each one; `flushMemo`
/// writes it to storage.
keeps_memo: bool = false,
memo: ?Memo = null,
/// Sources put since storage was last written. `put` only collects them, and `startWriting` stores them on another
/// thread while the build goes on; every later change to the cache waits for that thread first.
unwritten: Queue = .{},
writer: ?std.Thread = null,
writing: Writing = .{},
const Unwritten = struct { key: [32]u8, source: []u8, owner: Owner, retired: bool = false };
const Queue = struct { records: std.ArrayList(Unwritten) = .empty, has_retired: bool = false };

/// What the writer thread did, read once it was joined.
const Writing = struct {
    queue: Queue = .{},
    written: usize = 0,
    io_errors: usize = 0,
    last_io_error: ?anyerror = null,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn initPersistent(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, compiler_digest: [32]u8) std.mem.Allocator.Error!Self {
    return .{ .allocator = allocator, .storage = .{ .io = io, .directory = try allocator.dupe(u8, directory), .compiler_hex = std.fmt.bytesToHex(compiler_digest, .lower) } };
}

pub fn deinit(self: *Self) void {
    self.flush();
    self.unwritten.records.deinit(self.allocator);

    for (self.entries.keys.items, self.entries.values.items) |name, entry| {
        self.allocator.free(name);
        self.sourceAllocator(entry.owner).free(entry.source);
    }

    self.entries.deinit(self.allocator);

    if (self.memo) |*memo| memo.deinit();
    if (self.storage) |storage| self.allocator.free(storage.directory);

    self.* = undefined;
}

pub fn get(self: *Self, name: []const u8, key: [32]u8) std.mem.Allocator.Error!?[]const u8 {
    var fetched = try self.fetch(name, key, .cache);

    defer self.releaseFetched(fetched);

    return self.record(name, key, &fetched);
}

/// What `fetch` found for one unit, before `record` accounts for it.
pub const Fetched = struct {
    source: ?[]u8 = null,
    failure: ?anyerror = null,
    kind: Kind = .absent,
    owner: Owner = .cache,
    pub const Kind = enum(u8) { held, stored, absent, invalid, failed };
};

/// A parallel search uses the shared allocator for disk buffers. Cache metadata stays on the caller's allocator.
pub fn fetch(self: *const Self, name: []const u8, key: [32]u8, owner: Owner) std.mem.Allocator.Error!Fetched {
    const entry = self.entries.getPtr(name);
    const cached = if (entry) |value| &value.key else null;

    switch (policy.lookup(cached, &key, self.storage != null)) {
        .Held => return .{ .source = entry.?.source, .kind = .held },
        .Missing => return .{},
        .Stored => {},
    }

    const source = self.storage.?.read(self.sourceAllocator(owner), key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCache => return .{ .kind = .invalid },
        else => return .{ .failure = err, .kind = .failed },
    } orelse return .{};

    return .{ .source = source, .kind = .stored, .owner = owner };
}

pub fn releaseFetched(self: *const Self, fetched: Fetched) void {
    if (fetched.kind == .stored) self.sourceAllocator(fetched.owner).free(fetched.source.?);
}

fn sourceAllocator(self: *const Self, owner: Owner) std.mem.Allocator {
    return switch (owner) {
        .cache => self.allocator,
        .shared => std.heap.smp_allocator,
    };
}

/// Takes ownership of a validated disk buffer after successful publication. The caller releases unconsumed results.
pub fn record(self: *Self, name: []const u8, key: [32]u8, fetched: *Fetched) std.mem.Allocator.Error!?[]const u8 {
    switch (fetched.kind) {
        .held => {
            self.reused += 1;

            return fetched.source.?;
        },
        .stored => {
            const source = fetched.source.?;

            try self.store(name, .{ .key = key, .source = source, .owner = fetched.owner }, false);

            fetched.* = .{};
            self.loaded += 1;
            self.reused += 1;

            return source;
        },
        .absent => return null,
        .invalid => {
            self.discarded += 1;

            return null;
        },
        .failed => {
            self.recordError(fetched.failure.?);

            return null;
        },
    }
}

pub fn put(self: *Self, name: []const u8, key: [32]u8, source: []const u8) std.mem.Allocator.Error!void {
    const owned = try self.allocator.dupe(u8, source);

    errdefer self.allocator.free(owned);

    return self.putOwned(name, key, owned, .cache);
}

/// Transfers an independently allocated buffer to the cache once publication succeeds.
pub fn putShared(self: *Self, name: []const u8, key: [32]u8, source: []u8) std.mem.Allocator.Error!void {
    try self.putOwned(name, key, source, .shared);
}

fn putOwned(self: *Self, name: []const u8, key: [32]u8, source: []u8, owner: Owner) std.mem.Allocator.Error!void {
    try self.store(name, .{ .key = key, .source = source, .owner = owner }, true);
}

/// Writes the sources put so far to storage on another thread, or here when no thread starts.
pub fn startWriting(self: *Self) void {
    self.runWriter(.Background);
}

/// Writes every source put so far before returning, as counting what was written expects.
pub fn flush(self: *Self) void {
    self.runWriter(.Synchronous);
}

/// Waits for the writes `startWriting` began and accounts for them.
pub fn finishWriting(self: *Self) void {
    self.runWriter(.Wait);
}

fn runWriter(self: *Self, mode: policy.Mode) void {
    const active = self.writing.queue.records.items.len != 0;
    const waiting = self.unwritten.records.items.len != 0;

    if (!active and (mode == .Wait or !waiting)) return;

    const plan: policy.Schedule = if (comptime generated_parser) blk: {
        const entry = @import("generated_run_generation_cache_writer");
        const Input = std.meta.Child(entry.Input);

        const input: Input = .{
            .mode = @fromBackingInt(@intCast(@backingInt(mode))),
            .active = active,
            .threaded = self.writer != null,
            .waiting = waiting,
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        const planned = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

        break :blk .{
            .finish = @fromBackingInt(@intCast(@backingInt(planned.finish))),
            .start = @fromBackingInt(@intCast(@backingInt(planned.start))),
        };
    } else policy.schedule(mode, active, self.writer != null, waiting);

    self.completeWrites(plan.finish);

    switch (plan.start) {
        .Idle => {},
        .Drain => self.startWrites(false),
        .Spawn => self.startWrites(true),
        .Join => unreachable,
    }
}

fn startWrites(self: *Self, background: bool) void {
    self.writing = .{ .queue = self.unwritten };
    self.unwritten = .{};

    if (background) {
        self.writer = std.Thread.spawn(.{}, writeAllInto, .{ self.storage.?, &self.writing }) catch null;

        if (self.writer != null) return;
    }

    self.completeWrites(.Drain);
}

fn completeWrites(self: *Self, action: policy.Action) void {
    switch (action) {
        .Idle => return,
        .Join => {
            self.writer.?.join();

            self.writer = null;
        },
        .Drain => writeAllInto(self.storage.?, &self.writing),
        .Spawn => unreachable,
    }

    if (self.writing.last_io_error) |err| self.last_io_error = err;

    self.written += self.writing.written;
    self.io_errors += self.writing.io_errors;

    if (self.writing.queue.has_retired) {
        if (comptime generated_parser) {
            self.publishWrites();
        } else {
            for (self.writing.queue.records.items) |item| {
                if (item.retired) self.sourceAllocator(item.owner).free(item.source);
            }
        }
    }

    self.writing.queue.records.deinit(self.allocator);

    self.writing = .{};
}

fn publishWrites(self: *Self) void {
    const rule = @import("generated_generation_cache_write_publication");
    const Input = std.meta.Child(rule.Input);
    const records = self.writing.queue.records.items;
    const flags = memory.borrowReadColumn(bool, "retired", records);
    var input: Input = .{ .flags = @ptrCast(&flags), .first = 0, .count = records.len };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    while (rule.executeIn(fixed.allocator(), &input) catch unreachable) |row| {
        const item = records[@intCast(row)];

        self.sourceAllocator(item.owner).free(item.source);

        input.first = row + 1;
    }
}

const WriteBatch = struct {
    storage: Storage,
    items: []const Unwritten,
    next: std.atomic.Value(usize) = .init(0),
    written: [writers]u64 = @splat(0),
    failures: [writers]u64 = @splat(0),
    last_io_error: [1]u32 = .{0},
    fn write(self: *const WriteBatch, index: usize) ?u32 {
        const item = self.items[index];
        const written = self.storage.write(std.heap.smp_allocator, item.key, item.source) catch |err| return @intFromError(err);

        return if (written) 0 else null;
    }
    fn run(self: *WriteBatch, participant: usize) void {
        var written: u64 = 0;
        var failures: u64 = 0;

        while (true) {
            const index = self.next.fetchAdd(1, .monotonic);

            if (index >= self.items.len) break;

            const code = self.write(index) orelse continue;

            if (code == 0) {
                written += 1;
            } else {
                failures += 1;

                @atomicStore(u32, &self.last_io_error[0], code, .monotonic);
            }
        }

        self.written[participant] = written;
        self.failures[participant] = failures;
    }
};

/// Writes separate cache files concurrently using the shared worker pool.
fn writeAllInto(storage: Storage, writing: *Writing) void {
    const items = writing.queue.records.items;
    var batch = WriteBatch{ .storage = storage, .items = items };
    const participants = @min(writers, items.len);

    zx.parallel.spread(WriteBatch, &batch, WriteBatch.run, participants);
    collectWrites(writing, batch.written[0..participants], batch.failures[0..participants]);

    const code = batch.last_io_error[0];

    if (code != 0) writing.last_io_error = @errorFromInt(@as(u16, @intCast(code)));
}

fn collectWrites(writing: *Writing, written: []const u64, failures: []const u64) void {
    if (comptime !@import("parser_options").generated_parser) {
        for (written, failures) |count, errors| {
            writing.written += @intCast(count);
            writing.io_errors += @intCast(errors);
        }

        return;
    }

    const summary = @import("generated_generation_cache_write_results");
    const input: std.meta.Child(summary.Input) = .{ .written = written, .failures = failures };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const totals = zx.columns.invoke(summary.executeValue, fixed.allocator(), &input) catch unreachable;
    writing.written += @intCast(totals.written);
    writing.io_errors += @intCast(totals.failures);
}

const writers = 8;

/// Holds disk-backed analyses until flushMemo. A resident caller also keeps the visit trace for its next request.
pub fn keepMemo(self: *Self) std.mem.Allocator.Error!?*Memo {
    if (self.memo == null) {
        self.memo = try @import("uniqueness_memo.zig").load(self.allocator, self);

        if (self.memo) |*memo| memo.record_trace = true;
    }

    self.keeps_memo = true;

    return if (self.memo) |*memo| memo else null;
}

/// Writes the memo this cache keeps to storage, so later generations in other processes reuse it.
pub fn flushMemo(self: *Self) std.mem.Allocator.Error!void {
    if (self.memo) |*memo| try @import("uniqueness_memo.zig").save(self.allocator, self, memo);
}

const Record = struct {
    cache: *Self,
    name: []const u8,
    found: Index.Position,
    value: Entry,
    fn write(self: *const Record, pending: ?usize) std.mem.Allocator.Error!void {
        const cache = self.cache;
        var value = self.value;

        value.pending = pending;

        if (self.found.row) |row| {
            cache.entries.values.items[row] = value;
        } else {
            const slot = try cache.entries.prepare(cache.allocator, self.name, self.found.slot);
            const owned_name = try cache.allocator.dupe(u8, self.name);

            cache.entries.append(slot, owned_name, value);
        }
    }
};

fn store(self: *Self, name: []const u8, value: Entry, enqueue: bool) std.mem.Allocator.Error!void {
    const found = self.entries.position(name);
    const previous = if (found.row) |row| &self.entries.values.items[row] else null;
    const binding: Record = .{ .cache = self, .name = name, .found = found, .value = value };
    const queued: Unwritten = .{ .key = value.key, .source = value.source, .owner = value.owner };

    if (comptime generated_parser) {
        if (self.storage != null and enqueue) try self.unwritten.records.ensureUnusedCapacity(self.allocator, 1);

        const rule = @import("generated_store_generation_cache_record");
        const Input = std.meta.Child(rule.Input);
        const Prior = std.meta.Child(@typeInfo(@FieldType(Input, "previous")).optional.child);
        const prior: Prior = if (previous) |entry| .{ .pending = entry.pending, .source = entry.source } else undefined;
        const sources = memory.borrowReadColumn([]u8, "source", self.unwritten.records.items);

        const input: Input = .{
            .active = self.writing.queue.records.items.len != 0,
            .threaded = self.writer != null,
            .previous = if (previous != null) &prior else null,
            .queue = @ptrCast(&sources),
            .count = self.unwritten.records.items.len,
            .persistent = self.storage != null,
            .needs_write = enqueue,
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        const outcome = zx.columns.invoke(rule.executeValue, fixed.allocator(), &input) catch unreachable;

        self.completeWrites(@fromBackingInt(@intCast(@backingInt(outcome.finish))));

        if (outcome.release) {
            const entry = previous.?;

            self.sourceAllocator(entry.owner).free(entry.source);
        }

        const pending: ?usize = if (outcome.append) |row| @intCast(row) else null;

        try binding.write(pending);

        if (outcome.retire) |row| {
            self.unwritten.records.items[@intCast(row)].retired = true;

            self.unwritten.has_retired = true;
        }

        if (pending != null) self.unwritten.records.appendAssumeCapacity(queued);

        return;
    }

    const prior: ?policy.Previous = if (previous) |entry| if (entry.pending) |row| .{ .pending = row, .source = entry.source } else null else null;
    const plan = policy.replaceSeed(prior, self.unwritten.records.items, self.storage != null, enqueue);

    if (plan.append != null) try self.unwritten.records.ensureUnusedCapacity(self.allocator, 1);

    self.finishWriting();

    if (previous) |entry| {
        if (plan.retire) |row| {
            self.unwritten.records.items[row].retired = true;
            self.unwritten.has_retired = true;
        } else {
            self.sourceAllocator(entry.owner).free(entry.source);
        }
    }

    try binding.write(plan.append);
    if (plan.append != null) self.unwritten.records.appendAssumeCapacity(queued);
}

pub const residentPlan = policy.resident;

fn recordError(self: *Self, err: anyerror) void {
    self.io_errors += 1;
    self.last_io_error = err;
}
