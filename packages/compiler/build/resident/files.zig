//! The source files a resident generator read, with the metadata they were read under. A file whose inode, size and
//! modification and status-change times still match keeps its earlier text, the same bytes at the same address, so
//! later comparisons of unchanged sources are pointer checks. As in Zig's own cache, a match only counts once the
//! file's last change is older than the read by more than the clock's resolution could hide; a file changed close
//! to its read is read again. Replaced texts stay alive until `release`, since analyses may point into them.
const std = @import("std");
const compiler = @import("compiler");
const bytes = compiler.bytes;
const snapshot = compiler.input_snapshot;
const Self = @This();

gpa: std.mem.Allocator,
entries: bytes.Map(Entry) = .empty,
replaced: std.ArrayList([]u8) = .empty,
transient: std.ArrayList(Transient) = .empty,
retained_bytes: usize = 0,
active_bytes: usize = 0,
/// What vouches for a file's text: it is the same file, of the same size, unchanged since.
pub const Metadata = snapshot.Metadata;

const Entry = struct {
    metadata: Metadata,
    read: i96,
    text: []u8,
    digest: ?[32]u8 = null,
    borrowable: bool,
    retained: bool = false,
};

const Transient = struct { text: []u8, borrowable: bool, retained: bool };

pub fn deinit(self: *Self) void {
    self.endRequest();
    self.release();
    self.replaced.deinit(self.gpa);
    self.transient.deinit(self.gpa);

    var entries = self.entries.iterator();

    while (entries.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        self.gpa.free(entry.value_ptr.text);
    }

    self.entries.deinit(self.gpa);
}

/// The contents of `path` in `directory`, keyed by `key`, which names the file across requests.
pub fn read(self: *Self, io: std.Io, directory: std.Io.Dir, path: []const u8, key: []const u8, borrowable: bool) ![]const u8 {
    if (try self.unchanged(io, directory, path, key, null)) |text| {
        if (borrowable) self.entries.getPtr(key).?.borrowable = true;

        return text;
    }

    const started = std.Io.Timestamp.now(io, .real).nanoseconds;
    const file = try directory.openFile(io, path, .{});

    defer file.close(io);

    const stat = try file.stat(io);
    const text = try self.gpa.alloc(u8, @intCast(stat.size));

    errdefer self.gpa.free(text);

    if (try file.readPositionalAll(io, text, 0) != text.len) return error.FileChanged;

    const found = try self.entries.getOrPut(self.gpa, key);
    var observed: Entry = .{ .metadata = metadata(stat), .read = started, .text = text, .borrowable = borrowable };

    if (found.found_existing) {
        const previous = found.value_ptr;

        if (bytes.equal(previous.text, text)) {
            self.gpa.free(text);

            observed.text = previous.text;
            observed.digest = previous.digest;
            observed.borrowable = observed.borrowable or previous.borrowable;
            observed.retained = previous.retained;
            previous.* = observed;

            return observed.text;
        }

        if (previous.retained) try self.replaced.ensureUnusedCapacity(self.gpa, self.transient.items.len + 1);
        try self.transient.append(self.gpa, .{ .text = previous.text, .borrowable = previous.borrowable, .retained = previous.retained });

        self.active_bytes -= previous.text.len;
    } else {
        found.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
            self.entries.removeByPtr(found.key_ptr);

            return err;
        };
    }

    found.value_ptr.* = observed;
    self.active_bytes += text.len;

    return text;
}

/// The text kept for `key` while the metadata of `path` in `directory` vouches for it: `known` when the listing of
/// `directory` gave it, otherwise read here. It only looks, so several threads may ask at once while none reads.
pub fn unchanged(self: *const Self, io: std.Io, directory: std.Io.Dir, path: []const u8, key: []const u8, known: ?Metadata) !?[]const u8 {
    const entry = self.entries.get(key) orelse return null;
    const found = known orelse metadata(try directory.statFile(io, path, .{}));

    return if (snapshot.residentReuse(entry.metadata, found, entry.read)) entry.text else null;
}

pub fn metadata(stat: std.Io.File.Stat) Metadata {
    return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
}

pub const Version = struct { metadata: Metadata, read: i96 };

pub fn version(self: *const Self, key: []const u8) ?Version {
    const entry = self.entries.get(key) orelse return null;

    return .{ .metadata = entry.metadata, .read = entry.read };
}

/// The Blake3 digest of `text`, remembered with the text `read` returned for `key` so an unchanged file is hashed once.
pub fn digest(self: *Self, key: []const u8, text: []const u8) [32]u8 {
    const entry = self.entries.getPtr(key) orelse return hash(text);

    if (entry.text.ptr != text.ptr or entry.text.len != text.len) return hash(text);
    if (entry.digest == null) entry.digest = hash(text);

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

    var entries = self.entries.valueIterator();

    while (entries.next()) |entry| entry.retained = false;
}

pub fn reserveAnalysis(self: *Self) std.mem.Allocator.Error!void {
    var count: usize = 0;

    for (self.transient.items) |previous| count += @intFromBool(previous.borrowable);
    try self.replaced.ensureUnusedCapacity(self.gpa, count);
}

pub fn keepAnalysis(self: *Self) void {
    var entries = self.entries.valueIterator();

    while (entries.next()) |entry| entry.retained = entry.borrowable;

    self.retire(true);
}

pub fn endRequest(self: *Self) void {
    self.retire(false);
}

fn retire(self: *Self, published: bool) void {
    for (self.transient.items) |previous| {
        if (previous.retained or (published and previous.borrowable)) {
            self.replaced.appendAssumeCapacity(previous.text);

            self.retained_bytes += previous.text.len;
        } else self.gpa.free(previous.text);
    }

    self.transient.clearRetainingCapacity();
}
