const std = @import("std");
const Round = @import("round.zig");
const Summaries = @import("../summaries.zig");
const Level = @import("../level.zig").Level;
const Self = @This();

allocator: std.mem.Allocator,
queue: std.ArrayList(u64) = .empty,
head: usize = 0,
queued: []bool,
budget: u64 = 0,
grew: bool = false,
pub fn init(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Self {
    return .{ .allocator = allocator, .queued = try allocator.alloc(bool, size) };
}

pub fn deinit(self: *Self) void {
    self.queue.deinit(self.allocator);
    self.allocator.free(self.queued);
}

pub fn prepare(self: *Self, summaries: *const Summaries, active: []const bool, known: []const bool, phase: Round.Phase, exhausted: bool) std.mem.Allocator.Error!void {
    if (phase == .Settle) summaries.reset(active, known);
    if (phase == .Demand and exhausted) summaries.clear();
    try self.fill(active);

    self.budget = 64 * @as(u64, self.queued.len);
    self.grew = false;
}

fn fill(self: *Self, active: []const bool) std.mem.Allocator.Error!void {
    self.queue.clearRetainingCapacity();

    self.head = 0;

    @memset(self.queued, false);

    for (active, 0..) |enabled, index| {
        if (enabled) try self.push(index);
    }
}

pub fn push(self: *Self, index: usize) std.mem.Allocator.Error!void {
    if (self.queued[index]) return;

    self.queued[index] = true;

    try self.queue.append(self.allocator, index);
}

pub fn enqueue(self: *Self, dirty: []bool, indices: []const u64) std.mem.Allocator.Error!void {
    for (indices) |value| {
        const index: usize = @intCast(value);

        dirty[index] = true;

        try self.push(index);
    }
}

pub fn notify(self: *Self, dirty: []bool, active: []const bool, changed: []const u64, callers: []const u64, demand_body: ?usize) std.mem.Allocator.Error!void {
    for (changed) |value| {
        const index: usize = @intCast(value);

        if (demand_body == index) {
            try self.enqueue(dirty, callers);
        } else if (active[index]) {
            try self.enqueue(dirty, &.{value});
        }
    }
}

pub fn publish(self: *Self, settlement: Round.Settlement) std.mem.Allocator.Error!void {
    try self.notify(settlement.dirty, settlement.active, settlement.changed, &.{}, null);
    if (settlement.body >= settlement.outputs.len) return;

    var weakened = false;

    for (settlement.levels, settlement.outputs[settlement.body]) |next, *current| {
        const met = current.meet(next);

        if (met == current.*) continue;

        Level.store(current, met);

        weakened = true;
    }

    if (weakened) try self.enqueue(settlement.dirty, settlement.callers);
}

pub fn pop(self: *Self) std.mem.Allocator.Error!?usize {
    if (self.head == self.queue.items.len) return null;

    const index: usize = @intCast(self.queue.items[self.head]);

    self.head += 1;
    self.queued[index] = false;

    return index;
}

fn take(self: *Self, phase: Round.Phase) std.mem.Allocator.Error!Round.Visit {
    const index = try self.pop() orelse return .done;

    if (phase == .Settle) {
        if (self.budget == 0) return .exhausted;

        self.budget -= 1;
    }

    return .{ .body = index };
}

fn pending(self: *const Self) Round.Window {
    return .{ .first = self.queue.items[self.head..] };
}

pub fn advance(self: *Self, phase: Round.Phase, frame: *const Round.Frame, previous: ?Round.Feedback, following: bool) std.mem.Allocator.Error!Round.Claim {
    if (previous) |result| {
        const callers = frame.callers[result.body];

        if (phase == .Settle) {
            try self.publish(.{ .active = frame.active, .outputs = frame.outputs, .dirty = frame.dirty, .changed = result.changed, .callers = callers, .body = result.body, .levels = result.levels });
        } else {
            try self.notify(frame.dirty, frame.active, result.changed, callers, result.body);
        }

        self.grew = self.grew or result.grew;
    }

    const queued = self.pending();
    const visit = try self.take(phase);

    return .{ .visit = visit, .pending = queued, .grew = self.grew, .prefetch = !following and visit == .body };
}
