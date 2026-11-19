const std = @import("std");
const Self = @This();

pub const State = union(enum) {
    missing,
    failed: anyerror,
    other: std.Io.File.Kind,
    file: Content,
    directory: Content,
};

pub const Content = struct { digest: [32]u8, physical_path: []const u8 };
pub const Entry = struct { path: []const u8, state: State, directory_entries: bool = false };

arena: std.heap.ArenaAllocator,
entries: []const Entry,

consistent: bool = true,
pub fn deinit(self: *Self) void {
    self.arena.deinit();

    self.* = undefined;
}

pub fn unchanged(self: Self, io: std.Io, allocator: std.mem.Allocator) !bool {
    if (!self.consistent) return false;

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    for (self.entries) |entry| {
        const current = try readWithDirectoryEntries(io, scratch.allocator(), entry.path, entry.directory_entries);

        if (!sameState(entry.state, current)) return false;

        _ = scratch.reset(.retain_capacity);
    }

    return true;
}

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
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .missing,
        else => return err,
    };

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

    return .{ .file = .{ .digest = digest, .physical_path = physical } };
}
