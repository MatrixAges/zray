const std = @import("std");
const Snapshot = @import("snapshot.zig");
const Self = @This();

const Observation = struct {
    state: Snapshot.State,
    consumed: bool = false,
    directory_entries: bool = false,
};

arena: std.heap.ArenaAllocator,
cwd: []const u8,
entries: std.StringHashMapUnmanaged(Observation) = .empty,
consistent: bool = true,
retain_versions: bool = false,
previous: ?Snapshot = null,
published: ?Snapshot = null,
pub fn init(io: std.Io, allocator: std.mem.Allocator) !Self {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena.allocator());

    return .{ .arena = arena, .cwd = cwd };
}

pub fn deinit(self: *Self) void {
    if (self.published) |*snapshot| snapshot.deinit();

    self.arena.deinit();

    self.* = undefined;
}

pub fn add(self: *Self, io: std.Io, path: []const u8) !void {
    return self.addWithDirectoryEntries(io, path, false);
}

pub fn addDirectory(self: *Self, io: std.Io, path: []const u8) !void {
    return self.addWithDirectoryEntries(io, path, true);
}

fn addWithDirectoryEntries(self: *Self, io: std.Io, path: []const u8, directory_entries: bool) !void {
    const normalized = try std.fs.path.resolve(self.arena.allocator(), &.{ self.cwd, path });
    const entry = try self.entries.getOrPut(self.arena.allocator(), normalized);

    if (entry.found_existing and (!directory_entries or entry.value_ptr.directory_entries)) return;

    if (!entry.found_existing and !directory_entries) {
        if (self.previous) |previous| {
            if (previous.find(normalized)) |prior| {
                const matched = prior.stillMatches(io) catch |err| {
                    entry.value_ptr.* = .{ .state = .{ .failed = err } };

                    return err;
                };

                if (matched) {
                    entry.value_ptr.* = .{ .state = prior.state };

                    return;
                }
            }
        }
    }

    const state = Snapshot.readWithDirectoryEntries(io, self.arena.allocator(), normalized, directory_entries) catch |err| {
        if (entry.found_existing) self.consistent = false;

        entry.value_ptr.* = .{ .state = .{ .failed = err }, .directory_entries = directory_entries };

        return err;
    };

    if (entry.found_existing) {
        const current_state = try Snapshot.readWithDirectoryEntries(io, self.arena.allocator(), normalized, entry.value_ptr.directory_entries);

        self.consistent = self.consistent and Snapshot.sameState(entry.value_ptr.state, current_state);
    }

    const consumed = entry.found_existing and entry.value_ptr.consumed;

    entry.value_ptr.* = .{ .state = state, .directory_entries = directory_entries, .consumed = consumed };
}

pub fn record(self: *Self, io: std.Io, path: []const u8, source: []const u8) !void {
    const allocator = self.arena.allocator();
    const normalized = try std.fs.path.resolve(allocator, &.{ self.cwd, path });
    const entry = try self.entries.getOrPut(allocator, normalized);

    const physical = std.Io.Dir.cwd().realPathFileAlloc(io, normalized, allocator) catch |err| {
        self.consistent = false;
        entry.value_ptr.* = .{ .state = .{ .failed = err } };

        return err;
    };

    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});

    const state = Snapshot.State{ .file = .{ .digest = digest, .physical_path = physical } };

    if (entry.found_existing and entry.value_ptr.consumed) {
        self.consistent = self.consistent and Snapshot.sameState(entry.value_ptr.state, state);
    }

    entry.value_ptr.* = .{ .state = state, .consumed = true };
}

pub fn observed(self: *const Self, allocator: std.mem.Allocator) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const owned = arena.allocator();
    const entries = try owned.alloc(Snapshot.Entry, self.entries.count());
    var iterator = self.entries.iterator();
    var index: usize = 0;

    while (iterator.next()) |entry| : (index += 1) {
        const path = try owned.dupe(u8, entry.key_ptr.*);

        const state = switch (entry.value_ptr.state) {
            .directory => |directory| Snapshot.State{ .directory = .{ .digest = directory.digest, .physical_path = try owned.dupe(u8, directory.physical_path) } },
            .file => |file| Snapshot.State{ .file = .{ .digest = file.digest, .physical_path = try owned.dupe(u8, file.physical_path) } },
            else => entry.value_ptr.state,
        };

        entries[index] = .{ .path = path, .state = state, .directory_entries = entry.value_ptr.directory_entries };
    }

    std.mem.sort(Snapshot.Entry, entries, {}, lessThan);

    return .{ .arena = arena, .entries = entries, .consistent = self.consistent };
}

pub fn verify(self: *const Self, io: std.Io, allocator: std.mem.Allocator, snapshot: Snapshot) !bool {
    if (!self.retain_versions) return snapshot.unchanged(io, allocator);

    return snapshot.verifyVersions(io, allocator);
}

pub fn retainPublished(self: *Self, snapshot: Snapshot) bool {
    if (!self.retain_versions) return false;

    std.debug.assert(self.published == null);

    self.published = snapshot;

    return true;
}

pub fn takePublished(self: *Self) ?Snapshot {
    defer self.published = null;

    return self.published;
}

fn lessThan(_: void, left: Snapshot.Entry, right: Snapshot.Entry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}
