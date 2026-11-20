const std = @import("std");
const Function = @import("function.zig");
const Level = @import("level.zig").Level;
const Growth = @import("growth.zig");
const Memo = @import("memo.zig");
const Pool = @import("pool.zig");
const Slots = @import("slots.zig");
const Summaries = @import("summaries.zig");
const Bodies = @import("program/bodies.zig");
const Schedule = if (@import("genz_options").generated_analysis) @import("ahead/schedule.zig") else @import("ahead/seed.zig");
const Self = @This();

/// Body analyses run ahead of the worklist on background threads. The worklist visits one body at a time, and a visit
/// may weaken what later visits read, so background threads analyze the next bodies of the queue against the summaries
/// as they stand while the worklist goes on, and each result lists the summary levels it read. A visit uses the result
/// only if every level it read still holds: the analysis reads nothing else that changes, so it would read the same
/// levels and reach the same result again, which keeps every result and the order of the worklist those of visiting
/// one body at a time. A body that calls itself reads what its own visit changes, so it is never analyzed ahead.
pool: *Pool,
slots: Slots,
summaries: *Summaries,
bodies: *const Bodies,
/// Where each body's analysis ahead stands; a background thread owns the body while it runs.
states: []u32,
recursive: []const bool,
/// Bodies whose summaries changed since their analysis ahead was requested, so that it is likely stale.
dirty: []bool,
settled: []Settled,
demanded: []Demanded,
planned: []Function.Plan,
pub const Settled = struct { passed: []const Function.Contribution, output: []const Level, reads: []const Function.Read };

pub const Demanded = struct { marks: []const Function.Mark, grew: bool, growth: Growth.Rows, reads: []const Function.Read };

pub fn init(allocator: std.mem.Allocator, pool: *Pool, slots: Slots, summaries: *Summaries, bodies: *const Bodies, recursive: []const bool) std.mem.Allocator.Error!Self {
    const count = bodies.units.len;
    const states = try allocator.alloc(u32, count);
    const dirty = try allocator.alloc(bool, count);

    Schedule.reset(states, dirty);

    return .{
        .pool = pool,
        .slots = slots,
        .summaries = summaries,
        .bodies = bodies,
        .states = states,
        .recursive = recursive,
        .dirty = dirty,
        .settled = try allocator.alloc(Settled, count),
        .demanded = try allocator.alloc(Demanded, count),
        .planned = try allocator.alloc(Function.Plan, count),
    };
}

/// Starts analyzing ahead for the visits of `kind`.
pub fn begin(self: *Self, comptime kind: Memo.Kind) void {
    self.pool.serve(Self, Task(kind).run, self);
}

/// Waits for the analyses ahead still running and drops every result not visited, before the summaries change
/// outside the worklist.
pub fn finish(self: *Self) void {
    self.pool.drain();
    self.pool.forget();
    Schedule.reset(self.states, self.dirty);
}

/// Queues the bodies of `indices` that have no analysis ahead or one that a summary change made stale, skipping those
/// whose result the memo already holds.
pub fn request(self: *Self, comptime kind: Memo.Kind, memo: *Memo, indices: @import("work/round.zig").Window) std.mem.Allocator.Error!void {
    const workers = self.pool.count();

    if (workers == 0 or indices.first.len == 0) return;

    var first: usize = 0;

    while (Schedule.scan(self.states, self.dirty, self.recursive, indices, first, workers)) |pos| {
        const index: usize = @intCast(indices.at(pos));

        first = pos + 1;

        if ((kind != .planned or memo.persistent) and try memo.holds(kind, self.summaries, self.bodies.state(self.summaries, index))) {
            _ = Schedule.transition(self.states, index, .Hold);

            continue;
        }

        _ = Schedule.transition(self.states, index, .Queue);

        if (!self.pool.submit(@intCast(index))) {
            // An older ring entry can claim the new reservation before submit observes a full ring.
            _ = Schedule.transition(self.states, index, .Withdraw);

            return;
        }
    }
}

/// The result analyzed ahead for body `index` if every level it read still holds; waits while it is analyzed.
pub fn take(self: *Self, comptime kind: Memo.Kind, index: usize) std.mem.Allocator.Error!?Found(kind) {
    if (self.pool.count() == 0 or !try Schedule.take(self.states, self.dirty, index)) return null;

    const found = @field(self, @tagName(kind))[index];

    return if (kind == .planned or Function.unchanged(self.summaries, found.reads)) found else null;
}

/// Where the calling thread builds the passes over a body it analyzes itself.
pub fn kept(self: *const Self) std.mem.Allocator {
    return self.pool.workers[0].lasting.allocator();
}

pub fn Found(comptime kind: Memo.Kind) type {
    return switch (kind) {
        .settled => Settled,
        .demanded => Demanded,
        .planned => Function.Plan,
    };
}

fn Task(comptime kind: Memo.Kind) type {
    return struct {
        fn run(self: *Self, worker: *Pool.Worker, index: u32) void {
            if (!Schedule.transition(self.states, index, .Claim)) return;

            @field(self, @tagName(kind))[index] = analyze(self, worker, index) catch {
                _ = Schedule.transition(self.states, index, .Fail);

                return;
            };

            _ = Schedule.transition(self.states, index, .Complete);
        }
        fn analyze(ahead: *Self, worker: *Pool.Worker, index: usize) std.mem.Allocator.Error!Found(kind) {
            const summaries = ahead.summaries;
            const scratch = worker.scratch.allocator();
            const keep = worker.kept.allocator();
            const lasting = worker.lasting.allocator();

            switch (kind) {
                .settled => {
                    var analysis = try ahead.bodies.analyze(scratch, lasting, ahead.slots, summaries, index, null, true);

                    analysis.deferred = true;
                    const result = try analysis.settle(keep, if (index < summaries.output.len) summaries.output[index].len else 0);

                    return .{ .passed = result.passed, .output = result.output, .reads = result.reads };
                },
                .demanded => {
                    // The growth copies a demand pass leaves are its own; the body's stay as they were until its visit.
                    const generated = @import("genz_options").generated_analysis;
                    var growth = if (generated) ahead.bodies.units[index].growth else try ahead.bodies.units[index].growth.clone(scratch);
                    var analysis = try ahead.bodies.analyze(scratch, lasting, ahead.slots, summaries, index, &growth, true);
                    analysis.deferred = true;
                    const result = try analysis.demand(keep);

                    return .{ .marks = result.marks, .grew = analysis.grew, .growth = if (generated) growth else try growth.capture(keep), .reads = result.reads };
                },
                .planned => {
                    var analysis = try ahead.bodies.analyze(scratch, lasting, ahead.slots, summaries, index, null, false);

                    return analysis.plan(keep);
                },
            }
        }
    };
}
