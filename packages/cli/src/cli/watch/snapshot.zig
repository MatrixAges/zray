const std = @import("std");
const versions = @import("compiler").input_snapshot;
const Self = @This();
const scan = @import("observation/scan.zig").scan;
const reader = @import("observation/read.zig");
const equality = @import("cli_source").same;
const Fact = std.meta.Child(@FieldType(std.meta.Child(equality.Input), "left"));

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
    return scan(self, io, allocator, false, false);
}

pub fn verifyVersions(self: Self, io: std.Io, allocator: std.mem.Allocator) !bool {
    return scan(self, io, allocator, true, false);
}

pub fn poll(self: Self, io: std.Io, allocator: std.mem.Allocator) !bool {
    return scan(self, io, allocator, true, true);
}

pub const VerifiedFile = struct {
    metadata: versions.Metadata,
    read_at: i96,
    fn matches(self: VerifiedFile, io: std.Io, path: []const u8, target: []const u8) !bool {
        const stat = (try reader.statPath(io, path)) orelse return false;

        if (stat.kind != .file or versions.residentMark(self.metadata, reader.metadataOf(stat), self.read_at, .{}) == null) return false;

        var resolved: [std.Io.Dir.max_path_bytes]u8 = undefined;

        const length = std.Io.Dir.cwd().realPathFile(io, path, &resolved) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };

        return std.mem.eql(u8, target, resolved[0..length]);
    }
};

pub fn sameState(left: *const State, right: *const State) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return equality.executeValue(empty.allocator(), &.{ .left = &fact(left), .right = &fact(right) }) catch unreachable;
}

fn fact(state: *const State) Fact {
    var value: Fact = .{ .kind = .Missing, .tag = 0, .digest = &.{}, .physical_path = "" };

    switch (state.*) {
        .missing => {},
        .failed => |err| {
            value.kind = .Failed;
            value.tag = @intFromError(err);
        },
        .other => |kind| {
            value.kind = .Other;
            value.tag = @backingInt(kind);
        },
        .file => |*content| {
            value.kind = .File;
            value.digest = &content.digest;
            value.physical_path = content.physical_path;
        },
        .directory => |*content| {
            value.kind = .Directory;
            value.digest = &content.digest;
            value.physical_path = content.physical_path;
        },
    }

    return value;
}

pub fn readWithDirectoryEntries(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory_entries: bool) !State {
    var context: reader.Context = .{ .io = io, .allocator = allocator, .path = path };

    try reader.observe(&context, directory_entries);

    return context.result;
}
