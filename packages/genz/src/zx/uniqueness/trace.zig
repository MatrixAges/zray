const std = @import("std");
const Memo = @import("memo.zig");
const generated = @import("genz_options").generated_analysis;
const Self = @This();
const Control = if (@import("genz_options").generated_analysis) @import("replay/root.zig") else @import("replay/seed.zig");
/// The results every body met in one analysis of a program, visit by visit, with the states it met them in. An
/// analysis is deterministic, so a later analysis of the same program shape takes the same path as long as its changed
/// bodies meet the results recorded for them: the unchanged bodies are then handed their recorded results without
/// computing memo keys, and when the changed bodies agree in every recorded state the whole path is known up front.
pub const Digest = [32]u8;
pub const Kind = Memo.Kind;
pub const Selection = struct { following: bool, cursor: ?u32 = null };

arena: std.heap.ArenaAllocator,
/// The program shape and exported functions the analysis ran for.
key: Digest,
identities: []Digest,
callees: if (generated) struct { starts: []const u64, edges: []const u32 } else []const []const u32,
settled: Visits(Memo.Settled),
demanded: Visits(Memo.Demanded),
planned: Visits(Memo.Planned),
pub fn deinit(self: *Self) void {
    self.arena.deinit();

    self.* = undefined;
}

/// Each body's results and the states it met them in, in visit order: those of body `index` are at
/// `starts[index]..starts[index + 1]`.
fn Visits(comptime Result: type) type {
    return struct {
        starts: []u32,
        entries: []Log(Result).Entry,
    };
}

fn Log(comptime Value: type) type {
    return struct {
        owners: std.ArrayList(u32) = .empty,
        entries: std.ArrayList(Entry) = .empty,
        const Entry = struct { value: Value, state: []const u8 };

        fn append(self: *@This(), allocator: std.mem.Allocator, owner: u32, value: Value, state: []const u8) std.mem.Allocator.Error!void {
            try self.owners.ensureUnusedCapacity(allocator, 1);
            try self.entries.append(allocator, .{ .value = value, .state = state });

            self.owners.appendAssumeCapacity(owner);
        }
    };
}

/// One analysis following the trace an earlier one left, and recording its own.
pub const Replay = struct {
    allocator: std.mem.Allocator,
    recording: ?std.heap.ArenaAllocator = null,
    /// No longer followed once a changed body met a different result than recorded.
    trace: ?*const Self = null,
    changed: []const bool = &.{},
    control: Control = undefined,
    settled: Log(Memo.Settled) = .{},
    demanded: Log(Memo.Demanded) = .{},
    planned: Log(Memo.Planned) = .{},
    /// The state of the visit `recall` answered, which `met` records instead of the memo's.
    recalled: ?[]const u8 = null,
    key: Digest = undefined,
    identities: []const Digest = &.{},
    callees: []const []const u32 = &.{},
    /// Follows `previous` when it ran for the same program shape with every body calling the same functions, so the
    /// worklist meets the bodies in the same order as long as their results agree.
    pub fn init(allocator: std.mem.Allocator, backing: std.mem.Allocator, previous: ?*const Self, key: Digest, identities: []const Digest, callees: []const []const u32) std.mem.Allocator.Error!Replay {
        const control = try Control.init(allocator, previous, key, identities, callees);

        return .{ .allocator = allocator, .recording = .init(backing), .trace = if (control.active) previous else null, .changed = control.changes, .control = control, .key = key, .identities = identities, .callees = callees };
    }

    pub fn deinit(self: *Replay) void {
        if (self.recording) |*arena| arena.deinit();
    }
    /// The result body `index` met at this visit last time, while it is unchanged and the trace is followed.
    pub fn recall(self: *Replay, comptime kind: Kind, index: usize) std.mem.Allocator.Error!?Memo.Result(kind) {
        const trace = self.trace orelse return null;
        const visits = @field(trace, @tagName(kind));
        const cursor = (try self.select(kind, index, visits.starts, false)) orelse return null;
        const visit = visits.entries[cursor];
        self.recalled = visit.state;

        return visit.value;
    }
    /// Records the result body `index` met, in the state `recall` or the last lookup in `memo` encoded; a changed
    /// body that met another result than recorded ends the replay.
    pub fn met(self: *Replay, comptime kind: Kind, index: usize, value: Memo.Result(kind), memo: *const Memo) std.mem.Allocator.Error!void {
        const recording = if (self.recording) |*arena| arena.allocator() else return;
        const source = self.recalled orelse memo.lastState();
        const state = if (generated) try @import("retain.zig").state(recording, source) else try recording.dupe(u8, source);

        self.recalled = null;

        try @field(self, @tagName(kind)).append(self.allocator, @intCast(index), value, state);

        const trace = self.trace orelse return;
        const visits = @field(trace, @tagName(kind));
        const cursor = (try self.select(kind, index, visits.starts, true)) orelse return;

        if (!try agree(kind, self.allocator, visits.entries[cursor].value, value)) self.trace = null;
    }
    fn select(self: *Replay, comptime kind: Kind, index: usize, starts: []const u32, verify: bool) std.mem.Allocator.Error!?u32 {
        const selected = try self.control.select(self.allocator, kind, index, starts, verify);

        if (!selected.following) self.trace = null;

        return selected.cursor;
    }
    /// The trace of this analysis, for the next one.
    pub fn finish(self: *Replay) std.mem.Allocator.Error!Self {
        const arena = &self.recording.?;
        const allocator = arena.allocator();
        const columns = self.identities.len + 1;
        const starts = try allocator.alloc(u32, std.math.mul(usize, columns, @typeInfo(Kind).@"enum".field_names.len) catch return error.OutOfMemory);

        @memset(starts, 0);

        var result: Self = undefined;
        result.key = self.key;

        result.identities = if (generated)
            @constCast(std.mem.bytesAsSlice(Digest, try @import("retain.zig").state(allocator, std.mem.sliceAsBytes(self.identities))))

        else
            try allocator.dupe(Digest, self.identities);

        inline for (@typeInfo(Kind).@"enum".field_names, 0..) |kind, index| {
            const log = @field(self, kind);
            const Entry = std.meta.Child(@TypeOf(log.entries.items));

            @field(result, kind) = .{
                .starts = starts[index * columns ..][0..columns],
                .entries = try allocator.alloc(Entry, log.entries.items.len),
            };
        }

        if (generated) {
            try @import("replay/publication.zig").capture(allocator, self, &result);
        } else {
            try @import("replay/seed.zig").capture(allocator, self, &result);
        }

        result.arena = arena.*;
        self.recording = null;

        return result;
    }
};

/// Whether two results of `kind` have the same effect: growth copies are sets, whatever order they were listed in.
pub fn agree(comptime kind: Kind, allocator: std.mem.Allocator, left: Memo.Result(kind), right: Memo.Result(kind)) std.mem.Allocator.Error!bool {
    if (@import("genz_options").generated_analysis) return @import("replay/ordered.zig").agree(kind, allocator, left, right);
    if (kind != .demanded) return same(left, right);
    if (left.grew != right.grew or !same(left.marks, right.marks)) return false;

    return try sameSet(Memo.Normalized, "id", allocator, left.normalized, right.normalized) and try sameSet(Memo.Renewed, "key", allocator, left.renewed, right.renewed);
}

fn sameSet(comptime Item: type, comptime key: []const u8, allocator: std.mem.Allocator, left: []const Item, right: []const Item) std.mem.Allocator.Error!bool {
    if (left.len != right.len) return false;
    if (same(left, right)) return true;

    const sorted = [2][]Item{ try allocator.dupe(Item, left), try allocator.dupe(Item, right) };

    defer for (sorted) |items| allocator.free(items);

    for (sorted) |items| std.mem.sortUnstable(Item, items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return order(@field(a, key)) < order(@field(b, key));
        }

        fn order(value: anytype) u64 {
            return if (@TypeOf(value) == u64) value else @backingInt(value);
        }
    }.less);

    return same(@as([]const Item, sorted[0]), sorted[1]);
}

/// Whether two results hold the same contents; whether a memo record was used is not part of a result.
fn same(left: anytype, right: @TypeOf(left)) bool {
    const T = @TypeOf(left);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout == .@"packed") return @as(info.backing_integer.?, @bitCast(left)) == @as(info.backing_integer.?, @bitCast(right));

            inline for (info.field_names) |field| {
                if (comptime std.mem.eql(u8, field, "used")) continue;
                if (!same(@field(left, field), @field(right, field))) return false;
            }

            return true;
        },
        .pointer => {
            if (left.len != right.len) return false;
            for (left, right) |item, other| if (!same(item, other)) return false;

            return true;
        },
        else => return left == right,
    }
}
