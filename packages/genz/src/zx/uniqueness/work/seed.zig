const std = @import("std");
const ir = @import("zx").ir;
const Round = @import("round.zig");
const Summaries = @import("../summaries.zig");
const Level = @import("../level.zig").Level;
const Self = @This();

allocator: std.mem.Allocator,
queue: std.ArrayList(u64) = .empty,
head: usize = 0,
queued: []bool,
pub fn init(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Self {
    return .{ .allocator = allocator, .queued = try allocator.alloc(bool, size) };
}

pub fn deinit(self: *Self) void {
    self.queue.deinit(self.allocator);
    self.allocator.free(self.queued);
}

pub fn prepare(self: *Self, program: *const ir.Program, summaries: *const Summaries, known: []const bool, reset: bool, clear: bool) std.mem.Allocator.Error!u64 {
    if (reset) summaries.reset(program.*, known);
    if (clear) summaries.clear();
    try self.fill(program);

    return 64 * @as(u64, self.queued.len);
}

fn fill(self: *Self, program: *const ir.Program) std.mem.Allocator.Error!void {
    self.queue.clearRetainingCapacity();

    self.head = 0;

    @memset(self.queued, false);

    for (program.functions.native_modules, 0..) |native, index| {
        if (native == null) try self.push(index);
    }

    if (!program.type_only) try self.push(program.functions.count());
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

pub fn notify(self: *Self, dirty: []bool, program: ir.Program, changed: []const u64, callers: []const u64, demand_body: ?usize) std.mem.Allocator.Error!void {
    const natives = program.functions.native_modules;

    for (changed) |value| {
        const index: usize = @intCast(value);

        if (demand_body == index) {
            try self.enqueue(dirty, callers);
        } else if (if (index < natives.len) natives[index] == null else !program.type_only) {
            try self.enqueue(dirty, &.{value});
        }
    }
}

pub fn publish(self: *Self, settlement: Round.Settlement) std.mem.Allocator.Error!void {
    try self.notify(settlement.dirty, settlement.program.*, settlement.changed, &.{}, null);
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

pub fn takeSettlement(self: *Self, budget: *u64) std.mem.Allocator.Error!Round.Visit {
    const index = try self.pop() orelse return .done;

    if (budget.* == 0) return .exhausted;

    budget.* -= 1;

    return .{ .body = index };
}

pub fn pending(self: *const Self) []const u64 {
    return self.queue.items[self.head..];
}
