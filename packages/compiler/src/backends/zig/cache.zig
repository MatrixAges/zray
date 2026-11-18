const std = @import("std");
const Storage = @import("cache/storage.zig");
const Self = @This();
const Owner = enum { cache, shared };
const Entry = struct { key: [32]u8, source: []u8, pending: ?usize = null, owner: Owner = .cache };
const Memo = @import("genz").zx.function_analysis.Uniqueness.Memo;

allocator: std.mem.Allocator,
entries: @import("zx").bytes.Map(Entry) = .empty,
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
unwritten: std.ArrayList(Unwritten) = .empty,
writer: ?std.Thread = null,
writing: Writing = .{},
const Unwritten = struct { key: [32]u8, source: []u8, owner: Owner, retired: bool = false };

/// What the writer thread did, read once it was joined.
const Writing = struct {
    queue: std.ArrayList(Unwritten) = .empty,
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
    self.unwritten.deinit(self.allocator);

    var iterator = self.entries.iterator();

    while (iterator.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.sourceAllocator(entry.value_ptr.owner).free(entry.value_ptr.source);
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
    if (self.entries.get(name)) |entry| {
        if (std.mem.eql(u8, &entry.key, &key)) return .{ .source = entry.source, .kind = .held };
    }

    const storage = self.storage orelse return .{};

    const source = storage.read(self.sourceAllocator(owner), key) catch |err| switch (err) {
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

            try self.store(name, .{ .key = key, .source = source, .owner = fetched.owner });

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
    if (self.storage != null) try self.unwritten.ensureUnusedCapacity(self.allocator, 1);

    const pending = if (self.storage != null) self.unwritten.items.len else null;

    try self.store(name, .{ .key = key, .source = source, .pending = pending, .owner = owner });
    if (pending != null) self.unwritten.appendAssumeCapacity(.{ .key = key, .source = source, .owner = owner });
}

/// Writes the sources put so far to storage on another thread, or here when no thread starts.
pub fn startWriting(self: *Self) void {
    self.finishWriting();

    if (self.unwritten.items.len == 0) return;

    self.takeWrites();

    self.writer = std.Thread.spawn(.{}, writeAllInto, .{ self.storage.?, &self.writing }) catch {
        self.finishWriting();

        return;
    };
}

/// Writes every source put so far before returning, as counting what was written expects.
pub fn flush(self: *Self) void {
    self.finishWriting();

    if (self.unwritten.items.len == 0) return;

    self.takeWrites();
    self.finishWriting();
}

/// Waits for the writes `startWriting` began and accounts for them.
pub fn finishWriting(self: *Self) void {
    if (self.writer) |thread| {
        thread.join();

        self.writer = null;
    } else if (self.writing.queue.items.len != 0) writeAllInto(self.storage.?, &self.writing);

    if (self.writing.queue.items.len == 0) return;

    self.written += self.writing.written;
    self.io_errors += self.writing.io_errors;

    if (self.writing.last_io_error) |err| self.last_io_error = err;
    for (self.writing.queue.items) |item| if (item.retired) self.sourceAllocator(item.owner).free(item.source);

    self.writing.queue.deinit(self.allocator);

    self.writing = .{};
}

fn takeWrites(self: *Self) void {
    self.writing = .{ .queue = self.unwritten };
    self.unwritten = .empty;
}

/// Writes every record on a few of the shared workers; records are separate files, which the file system creates
/// side by side, though beyond a few threads they wait on its locks.
fn writeAllInto(storage: Storage, writing: *Writing) void {
    const Records = struct {
        storage: Storage,
        items: []const Unwritten,
        next: std.atomic.Value(usize) = .init(0),
        written: std.atomic.Value(usize) = .init(0),
        io_errors: std.atomic.Value(usize) = .init(0),
        last_io_error: std.atomic.Value(u16) = .init(0),
        fn run(records: *@This(), _: usize) void {
            while (true) {
                const index = records.next.fetchAdd(1, .monotonic);

                if (index >= records.items.len) return;

                const item = records.items[index];

                const written = records.storage.write(std.heap.smp_allocator, item.key, item.source) catch |err| {
                    _ = records.io_errors.fetchAdd(1, .monotonic);

                    records.last_io_error.store(@intFromError(err), .monotonic);

                    continue;
                };

                if (written) _ = records.written.fetchAdd(1, .monotonic);
            }
        }
    };

    const items = writing.queue.items;
    var records = Records{ .storage = storage, .items = items };

    @import("zx").parallel.spread(Records, &records, Records.run, @min(writers, items.len));
    writing.written += records.written.load(.monotonic);
    writing.io_errors += records.io_errors.load(.monotonic);

    if (records.last_io_error.load(.monotonic) != 0) writing.last_io_error = @errorFromInt(records.last_io_error.load(.monotonic));
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

fn store(self: *Self, name: []const u8, value: Entry) std.mem.Allocator.Error!void {
    self.finishWriting();

    if (self.entries.getPtr(name)) |entry| {
        if (self.pendingWrite(entry.*)) |item| {
            item.retired = true;
        } else {
            self.sourceAllocator(entry.owner).free(entry.source);
        }

        entry.* = value;

        return;
    }

    const owned_name = try self.allocator.dupe(u8, name);

    errdefer self.allocator.free(owned_name);

    try self.entries.put(self.allocator, owned_name, value);
}

fn pendingWrite(self: *Self, entry: Entry) ?*Unwritten {
    const index = entry.pending orelse return null;

    if (index >= self.unwritten.items.len) return null;

    const item = &self.unwritten.items[index];

    return if (item.source.ptr == entry.source.ptr) item else null;
}

fn recordError(self: *Self, err: anyerror) void {
    self.io_errors += 1;
    self.last_io_error = err;
}
