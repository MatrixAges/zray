//! The source files a resident generator read, with the metadata they were read under. A file whose inode, size and
//! modification and status-change times still match keeps its earlier text, the same bytes at the same address, so
//! later comparisons of unchanged sources are pointer checks. As in Zig's own cache, a match only counts once the
//! file's last change is older than the read by more than the clock's resolution could hide; a file changed close
//! to its read is read again. Replaced texts stay alive until `release`, since analyses may point into them.
const std = @import("std");
const compiler = @import("compiler");
const snapshot = compiler.input_snapshot;
const retention = compiler.cache_retention;
const versions = compiler.file_versions;
const Self = @This();

gpa: std.mem.Allocator,
entries: compiler.SourceIndex(Entry) = .empty,
replaced: std.ArrayList([]u8) = .empty,
transient: std.ArrayList(Transient) = .empty,
clock: retention.Clock = .{},
retained_bytes: usize = 0,
counters: versions.Counters = .{},
/// What vouches for a file's text: it is the same file, of the same size, unchanged since.
pub const Metadata = snapshot.Metadata;

const Entry = struct {
    metadata: Metadata,
    read: i96,
    text: []u8,
    digest: ?[32]u8 = null,
    borrow_mark: u64,
};

const Transient = struct { text: []u8, retention: retention.Retention };

pub fn deinit(self: *Self) void {
    self.endRequest();
    self.release();
    self.replaced.deinit(self.gpa);
    self.transient.deinit(self.gpa);

    for (self.entries.keys.items, self.entries.values.items) |key, entry| {
        self.gpa.free(key);
        self.gpa.free(entry.text);
    }

    self.entries.deinit(self.gpa);
}

/// The contents of `path` in `directory`, keyed by `key`, which names the file across requests.
pub fn read(self: *Self, io: std.Io, directory: std.Io.Dir, path: []const u8, key: []const u8, borrowable: bool) ![]const u8 {
    return self.readObserved(io, directory, path, key, borrowable, null);
}

pub fn readObserved(self: *Self, io: std.Io, directory: std.Io.Dir, path: []const u8, key: []const u8, borrowable: bool, known: ?Metadata) ![]const u8 {
    const found = self.entries.position(key);
    const previous = if (found.row) |row| &self.entries.values.items[row] else null;

    if (previous) |entry| {
        const observed = known orelse metadata(try directory.statFile(io, path, .{}));

        if (snapshot.residentMark(entry.metadata, observed, entry.read, .{
            .previous = entry.borrow_mark,
            .current = self.clock.current,
            .borrowable = borrowable,
        })) |mark| {
            entry.borrow_mark = mark;

            return entry.text;
        }
    }

    const started = std.Io.Timestamp.now(io, .real).nanoseconds;
    const file = try directory.openFile(io, path, .{});

    defer file.close(io);

    const stat = try file.stat(io);
    const text = try self.gpa.alloc(u8, @intCast(stat.size));

    errdefer self.gpa.free(text);

    if (try file.readPositionalAll(io, text, 0) != text.len) return error.FileChanged;

    const plan = versions.update(.{
        .previous = if (previous) |entry| .{ .text = entry.text, .mark = entry.borrow_mark } else null,
        .text = text,
        .borrowable = borrowable,
        .clock = self.clock,
        .counters = self.counters,
    });

    var observed: Entry = .{ .metadata = metadata(stat), .read = started, .text = text, .borrow_mark = plan.mark };

    if (previous) |entry| {
        if (plan.reuse) {
            self.gpa.free(text);

            observed.text = entry.text;
            observed.digest = entry.digest;
            entry.* = observed;

            return observed.text;
        }

        const keep = plan.previous.?;

        if (keep.keep_on_abort) try self.replaced.ensureUnusedCapacity(self.gpa, plan.counters.abortable);
        try self.transient.append(self.gpa, .{ .text = entry.text, .retention = keep });

        entry.* = observed;
    } else {
        const slot = try self.entries.prepare(self.gpa, key, found.slot);
        const owned_key = try self.gpa.dupe(u8, key);

        self.entries.append(slot, owned_key, observed);
    }

    self.counters = plan.counters;

    return text;
}

/// The text kept for `key` while the metadata of `path` in `directory` vouches for it: `known` when the listing of
/// `directory` gave it, otherwise read here. It only looks, so several threads may ask at once while none reads.
pub fn unchanged(self: *const Self, io: std.Io, directory: std.Io.Dir, path: []const u8, key: []const u8, known: ?Metadata) !?[]const u8 {
    const entry = self.entries.getPtr(key) orelse return null;
    const found = known orelse metadata(try directory.statFile(io, path, .{}));

    return if (snapshot.residentMark(entry.metadata, found, entry.read, .{}) != null) entry.text else null;
}

pub fn metadata(stat: std.Io.File.Stat) Metadata {
    return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
}

pub const Version = struct { metadata: Metadata, read: i96 };

pub fn version(self: *const Self, key: []const u8) ?Version {
    const entry = self.entries.getPtr(key) orelse return null;

    return .{ .metadata = entry.metadata, .read = entry.read };
}

/// The Blake3 digest of `text`, remembered with the text `read` returned for `key` so an unchanged file is hashed once.
pub fn digest(self: *Self, key: []const u8, text: []const u8) [32]u8 {
    const entry = self.entries.getPtr(key) orelse return hash(text);

    switch (versions.digest(entry.text, text, entry.digest != null)) {
        .Hash => return hash(text),
        .Reuse => return entry.digest.?,
        .Save => entry.digest = hash(text),
    }

    return entry.digest.?;
}

fn hash(text: []const u8) [32]u8 {
    var result: [32]u8 = undefined;

    std.crypto.hash.Blake3.hash(text, &result, .{});

    return result;
}

/// Frees the texts replaced since the last call.
pub fn release(self: *Self) void {
    for (self.replaced.items) |text| self.gpa.free(text);

    self.replaced.clearRetainingCapacity();

    self.retained_bytes = 0;
    self.clock.published = 0;
}

pub fn reserveAnalysis(self: *Self) std.mem.Allocator.Error!void {
    try self.replaced.ensureUnusedCapacity(self.gpa, self.counters.publishable);
}

pub fn keepAnalysis(self: *Self) void {
    self.clock.publish();
    self.retire(true);
}

pub fn endRequest(self: *Self) void {
    self.retire(false);
}

fn retire(self: *Self, published: bool) void {
    const retired = versions.retire(self.transient.items, self.replaced.unusedCapacitySlice(), published);

    self.replaced.items.len += retired.count;
    self.retained_bytes += retired.bytes;

    for (self.transient.items) |previous| self.gpa.free(previous.text);

    self.transient.clearRetainingCapacity();

    self.counters.publishable = 0;
    self.counters.abortable = 0;
}
