const std = @import("std");
const Storage = @import("cache/storage.zig");
const policy = @import("cache/policy.zig");
const generated_parser = @import("parser_options").generated_parser;
const Self = @This();
const Owner = enum { cache, shared };
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
    source: ?[]const u8 = null,
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
            const source = @constCast(fetched.source.?);

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

    if (comptime generated_parser) {
        const entry = @import("generated_run_generation_cache_writer");
        const Input = std.meta.Child(entry.Input);

        const input: Input = .{
            .cache = @ptrCast(self),
            .mode = @enumFromInt(@intFromEnum(mode)),
            .active = active,
            .threaded = self.writer != null,
            .waiting = waiting,
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        entry.executeIn(fixed.allocator(), &input) catch unreachable;

        return;
    }

    const plan = policy.schedule(mode, active, self.writer != null, waiting);

    self.completeWrites(plan.finish);

    if (plan.start == .Idle) return;
    if (!startCacheWriting(@ptrCast(self), plan.start == .Spawn)) self.completeWrites(.Drain);
}

pub fn finishCacheWriting(target: *const anyopaque, join: bool) void {
    const self: *Self = @ptrCast(@alignCast(@constCast(target)));

    self.completeWrites(if (join) .Join else .Drain);
}

pub fn startCacheWriting(target: *const anyopaque, background: bool) bool {
    const self: *Self = @ptrCast(@alignCast(@constCast(target)));

    self.writing = .{ .queue = self.unwritten };
    self.unwritten = .{};

    if (!background) return false;

    self.writer = std.Thread.spawn(.{}, writeAllInto, .{ self.storage.?, &self.writing }) catch return false;

    return true;
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

    self.written += self.writing.written;
    self.io_errors += self.writing.io_errors;

    if (self.writing.last_io_error) |err| self.last_io_error = err;

    if (self.writing.queue.has_retired) {
        const records = self.writing.queue.records.items;
        var row = policy.nextRetired(records, 0);

        while (row < records.len) : (row = policy.nextRetired(records, row + 1)) {
            const item = records[row];

            self.sourceAllocator(item.owner).free(item.source);
        }
    }

    self.writing.queue.records.deinit(self.allocator);

    self.writing = .{};
}

/// Writes every record on a few of the shared workers; records are separate files, which the file system creates
/// side by side, though beyond a few threads they wait on its locks.
fn writeAllInto(storage: Storage, writing: *Writing) void {
    const Records = struct {
        storage: Storage,
        items: []const Unwritten,
        next: std.atomic.Value(usize) = .init(0),
        written: [writers]u64 = @splat(0),
        failures: [writers]u64 = @splat(0),
        last_io_error: std.atomic.Value(u16) = .init(0),
        fn run(records: *@This(), participant: usize) void {
            var written_count: u64 = 0;
            var failed_count: u64 = 0;

            while (true) {
                const index = records.next.fetchAdd(1, .monotonic);

                if (index >= records.items.len) break;

                const item = records.items[index];

                const written = records.storage.write(std.heap.smp_allocator, item.key, item.source) catch |err| {
                    failed_count += 1;

                    records.last_io_error.store(@intFromError(err), .monotonic);

                    continue;
                };

                if (written) written_count += 1;
            }

            records.written[participant] = written_count;
            records.failures[participant] = failed_count;
        }
    };

    const items = writing.queue.records.items;
    var records = Records{ .storage = storage, .items = items };
    const participants = @min(writers, items.len);

    @import("zx").parallel.spread(Records, &records, Records.run, participants);

    collectWrites(writing, records.written[0..participants], records.failures[0..participants]);

    if (records.last_io_error.load(.monotonic) != 0) writing.last_io_error = @errorFromInt(records.last_io_error.load(.monotonic));
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
    const totals = @import("zx").columns.invoke(summary.executeValue, fixed.allocator(), &input) catch unreachable;
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

fn store(self: *Self, name: []const u8, input: Entry, enqueue: bool) std.mem.Allocator.Error!void {
    const found = self.entries.position(name);
    const previous = if (found.row) |row| &self.entries.values.items[row] else null;
    const queued: ?policy.Previous = if (previous) |entry| if (entry.pending) |row| .{ .pending = row, .source = entry.source } else null else null;
    const plan = policy.replace(queued, self.unwritten.records.items, self.storage != null, enqueue);

    if (plan.append != null) try self.unwritten.records.ensureUnusedCapacity(self.allocator, 1);

    self.finishWriting();

    var value = input;

    value.pending = plan.append;

    if (previous) |entry| {
        if (plan.retire) |row| {
            self.unwritten.records.items[row].retired = true;
            self.unwritten.has_retired = true;
        } else {
            self.sourceAllocator(entry.owner).free(entry.source);
        }

        entry.* = value;
    } else {
        const slot = if (try self.entries.reserve(self.allocator)) self.entries.position(name).slot else found.slot;
        const owned_name = try self.allocator.dupe(u8, name);

        self.entries.append(slot, owned_name, value);
    }

    if (plan.append != null) self.unwritten.records.appendAssumeCapacity(.{ .key = value.key, .source = value.source, .owner = value.owner });
}

pub const residentPlan = policy.resident;

fn recordError(self: *Self, err: anyerror) void {
    self.io_errors += 1;
    self.last_io_error = err;
}
