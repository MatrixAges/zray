const std = @import("std");
const Snapshot = @import("snapshot.zig");
const Self = @This();

pub const Observation = struct {
    state: Snapshot.State,
    consumed: bool = false,
    directory_entries: bool = false,
};

pub const Observations = std.StringHashMapUnmanaged(Observation);
const registration = @import("observation/registration.zig");

arena: std.heap.ArenaAllocator,
cwd: []const u8,

entries: Observations = .empty,
consistent: bool = true,
retain_versions: bool = false,
previous: ?*const Snapshot = null,
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
    return registration.add(self, io, path, false);
}

pub fn addDirectory(self: *Self, io: std.Io, path: []const u8) !void {
    return registration.add(self, io, path, true);
}

pub fn record(self: *Self, io: std.Io, path: []const u8, source: []const u8) !void {
    return registration.record(self, io, path, source);
}

pub const observed = @import("observation/capture.zig").capture;

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
