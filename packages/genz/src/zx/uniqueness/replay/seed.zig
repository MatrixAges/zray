const std = @import("std");
const Self = @This();

active: bool,
changes: []bool,

cursors: [3][]u32 = @splat(&.{}),
pub fn init(allocator: std.mem.Allocator, previous: anytype, key: [32]u8, identities: []const [32]u8, callees: []const []const u32) std.mem.Allocator.Error!Self {
    const changes = try allocator.alloc(bool, identities.len);
    const trace = if (previous) |value| if (std.mem.eql(u8, &value.key, &key) and value.identities.len == identities.len) value else null else null;

    for (changes, 0..) |*target, index| target.* = if (trace) |value| !std.mem.eql(u8, &value.identities[index], &identities[index]) else true;

    var self = Self{ .active = trace != null, .changes = changes };

    if (trace) |value| {
        for (changes, 0..) |differs, index| if (differs and !std.mem.eql(u32, value.callees[index], callees[index])) {
            self.active = false;
        };
    }

    return self;
}

pub fn select(self: *Self, allocator: std.mem.Allocator, comptime kind: anytype, index: usize, starts: []const u32, verify: bool) std.mem.Allocator.Error!@import("../trace.zig").Selection {
    if (self.changes[index] != verify) return .{ .following = true };

    const positions = &self.cursors[@backingInt(kind)];

    if (positions.len == 0) positions.* = try allocator.dupe(u32, starts[0 .. starts.len - 1]);

    const cursor = &positions.*[index];
    const selected = cursor.*;

    if (selected == starts[index + 1]) return .{ .following = false };

    cursor.* += 1;

    return .{ .following = true, .cursor = selected };
}

pub fn capture(allocator: std.mem.Allocator, replay: anytype, trace: anytype) std.mem.Allocator.Error!void {
    const rows = try allocator.alloc([]const u32, replay.callees.len);

    for (rows, replay.callees) |*target, source| target.* = try allocator.dupe(u32, source);

    trace.callees = rows;

    inline for (.{ "settled", "demanded", "planned" }) |field| {
        const log = @field(replay, field);
        const visits = @field(trace, field);
        const Row = std.meta.Child(@TypeOf(visits.entries));

        group(Row, visits.starts, log.owners.items, log.entries.items, visits.entries);
    }
}

fn group(comptime Row: type, first: []u32, owners: []const u32, source: []const Row, target: []Row) void {
    for (owners) |body| first[body] += 1;
    for (1..first.len) |index| first[index] += first[index - 1];

    var index = owners.len;

    while (index != 0) {
        index -= 1;
        const body = owners[index];
        first[body] -= 1;
        target[first[body]] = source[index];
    }
}
