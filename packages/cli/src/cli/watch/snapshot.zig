const std = @import("std");
const versions = @import("compiler").input_snapshot;
const Self = @This();

pub const State = union(enum) {
    missing,
    failed: anyerror,
    other: std.Io.File.Kind,
    file: Content,
    directory: Content,
};

pub const Content = struct { digest: [32]u8, physical_path: []const u8 };

pub const Entry = struct {
    path: []const u8,
    state: State,
    directory_entries: bool = false,
    verified_file: ?VerifiedFile = null,
    pub fn stillMatches(self: *const Entry, io: std.Io) !bool {
        const verified = self.verified_file orelse return false;

        return verified.matches(io, self.path, self.state.file.physical_path);
    }
};

arena: std.heap.ArenaAllocator,
entries: []Entry,

consistent: bool = true,
pub fn find(self: Self, path: []const u8) ?*const Entry {
    const row = std.sort.binarySearch(Entry, self.entries, path, comparePath) orelse return null;

    return &self.entries[row];
}

fn comparePath(path: []const u8, entry: Entry) std.math.Order {
    return std.mem.order(u8, path, entry.path);
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();

    self.* = undefined;
}

pub fn unchanged(self: Self, io: std.Io, allocator: std.mem.Allocator) !bool {
    return self.scan(io, allocator, .content);
}

pub fn verifyVersions(self: Self, io: std.Io, allocator: std.mem.Allocator) !bool {
    return self.scan(io, allocator, .content_and_version);
}

pub fn poll(self: Self, io: std.Io, allocator: std.mem.Allocator) !bool {
    return self.scan(io, allocator, .reuse_version);
}

const Scan = enum { content, content_and_version, reuse_version };

fn scan(self: Self, io: std.Io, allocator: std.mem.Allocator, mode: Scan) !bool {
    if (!self.consistent) return false;

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const save_version = mode != .content;
    const started = if (save_version) std.Io.Timestamp.now(io, .real).nanoseconds else 0;

    for (self.entries) |*entry| {
        if (mode == .reuse_version and try entry.stillMatches(io)) continue;

        var verified_file: ?VerifiedFile = null;
        const current = try read(io, scratch.allocator(), entry.path, entry.directory_entries, started, if (save_version) &verified_file else null);

        if (!sameState(entry.state, current)) return false;
        if (save_version) entry.verified_file = verified_file;

        _ = scratch.reset(.retain_capacity);
    }

    return true;
}

const VerifiedFile = struct {
    metadata: versions.Metadata,
    read_at: i96,
    fn matches(self: VerifiedFile, io: std.Io, path: []const u8, target: []const u8) !bool {
        const stat = (try statPath(io, path)) orelse return false;

        if (stat.kind != .file or versions.residentMark(self.metadata, metadataOf(stat), self.read_at, .{}) == null) return false;

        var resolved: [std.Io.Dir.max_path_bytes]u8 = undefined;

        const length = std.Io.Dir.cwd().realPathFile(io, path, &resolved) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };

        return std.mem.eql(u8, target, resolved[0..length]);
    }
};

pub fn sameState(left: State, right: State) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

    return switch (left) {
        .missing => true,
        .failed => |err| err == right.failed,
        .other => |kind| kind == right.other,
        .directory => |directory| std.mem.eql(u8, &directory.digest, &right.directory.digest) and std.mem.eql(u8, directory.physical_path, right.directory.physical_path),
        .file => |file| std.mem.eql(u8, &file.digest, &right.file.digest) and std.mem.eql(u8, file.physical_path, right.file.physical_path),
    };
}

pub fn readWithDirectoryEntries(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory_entries: bool) !State {
    return read(io, allocator, path, directory_entries, 0, null);
}

fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory_entries: bool, started: i96, verified_file: ?*?VerifiedFile) !State {
    const stat = (try statPath(io, path)) orelse return .missing;

    if (stat.kind == .directory) return .{ .directory = .{
        .digest = if (directory_entries) try @import("directory.zig").digest(io, allocator, path) else try @import("../../package/workspace/directory.zig").digest(io, allocator, path),
        .physical_path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator),
    } };

    if (stat.kind != .file) return .{ .other = stat.kind };

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .missing,
        else => return err,
    };

    defer file.close(io);

    const before = if (verified_file != null) try file.stat(io) else undefined;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});

    while (true) {
        const bytes = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        hash.update(bytes);
        reader.interface.tossBuffered();
    }

    var digest: [32]u8 = undefined;

    hash.final(&digest);

    const physical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);

    if (verified_file) |verified| {
        const after = try file.stat(io);
        const metadata = metadataOf(after);

        if (before.kind == .file and after.kind == .file and versions.residentMark(metadataOf(before), metadata, started, .{}) != null) {
            verified.* = .{ .metadata = metadata, .read_at = started };
        }
    }

    return .{ .file = .{ .digest = digest, .physical_path = physical } };
}

fn statPath(io: std.Io, path: []const u8) !?std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
}

fn metadataOf(stat: std.Io.File.Stat) versions.Metadata {
    return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
}
