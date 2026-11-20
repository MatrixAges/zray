const std = @import("std");
const Function = @import("function.zig");
const Level = @import("level.zig").Level;
const Growth = @import("growth.zig");
const Memo = @import("memo.zig");
const Pool = @import("pool.zig");
const Slots = @import("slots.zig");
const Summaries = @import("summaries.zig");
const Bodies = @import("program/bodies.zig");
const generated = @import("genz_options").generated_analysis;
const Schedule = if (generated) @import("ahead/schedule.zig") else @import("ahead/seed.zig");
const workflow = @import("ahead/workflow.zig");
const compute = @import("program/visit/compute.zig");
const Window = @import("work/round.zig").Window;
const Error = std.mem.Allocator.Error;
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
/// A round publishes only one kind of result. It drains its workers before the table changes kind.
results: []Result,
const Result = union { settled: Settled, demanded: Demanded, planned: Function.Plan };

pub const Settled = struct { passed: []const Function.Contribution, output: []const Level, reads: []const Function.Read };
pub const Demanded = struct { marks: []const Function.Mark, grew: bool, growth: Growth.Rows, reads: []const Function.Read };

pub fn init(allocator: std.mem.Allocator, pool: *Pool, slots: Slots, summaries: *Summaries, bodies: *const Bodies, recursive: []const bool) Error!Self {
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
        .results = try allocator.alloc(Result, if (pool.count() == 0) 0 else count),
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
pub fn request(self: *Self, comptime kind: Memo.Kind, memo: *Memo, indices: Window) Error!void {
    const workers = self.pool.count();

    if (workers == 0 or indices.first.len == 0) return;
    if (kind != .planned) return self.offer(kind, true, memo, indices, workers);

    switch (memo.persistent) {
        inline else => |persistent| try self.offer(kind, persistent, memo, indices, workers),
    }
}

fn offer(self: *Self, comptime kind: Memo.Kind, comptime persistent: bool, memo: *Memo, indices: Window, workers: usize) Error!void {
    var first: usize = 0;

    offers: while (Schedule.scan(self.states, self.dirty, self.recursive, indices, first, workers)) |pos| {
        const index: usize = @intCast(indices.at(pos));
        var submitted: bool = undefined;

        first = pos + 1;

        inline for (comptime workflow.steps(.Request, kind, persistent)) |step| switch (step) {
            .CheckMemo => if (try memo.holds(kind, self.summaries, self.bodies.state(self.summaries, index))) {
                _ = Schedule.transition(self.states, index, .Hold);

                continue :offers;
            },
            .Reserve => _ = Schedule.transition(self.states, index, .Queue),
            .Submit => submitted = self.pool.submit(@intCast(index)),
            .WithdrawOnFull => if (!submitted) {
                // An older ring entry can claim the new reservation before submit observes a full ring.
                _ = Schedule.transition(self.states, index, .Withdraw);

                return;
            },
            else => unreachable,
        };
    }
}

/// The result analyzed ahead for body `index` if every level it read still holds; waits while it is analyzed.
pub fn take(self: *Self, comptime kind: Memo.Kind, index: usize) Error!?Found(kind) {
    if (self.pool.count() == 0) return null;

    var found: Found(kind) = undefined;

    inline for (comptime workflow.steps(.Collect, kind, true)) |step| switch (step) {
        .Wait => {
            if (!try Schedule.take(self.states, self.dirty, index)) return null;

            found = @field(self.results[index], @tagName(kind));
        },
        .CheckReads => if (!Function.unchanged(self.summaries, found.reads)) return null,
        else => unreachable,
    };

    return found;
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
            execute(self, worker, index) catch {
                _ = Schedule.transition(self.states, index, .Fail);
            };
        }
        fn execute(self: *Self, worker: *Pool.Worker, index: usize) Error!void {
            var result: Found(kind) = undefined;
            var growth: Growth.Store = undefined;

            var input: compute.Input = .{
                .bodies = self.bodies,
                .slots = self.slots,
                .summaries = self.summaries,
                .body = index,
                .growth = null,
                .scratch = worker.scratch.allocator(),
                .lasting = worker.lasting.allocator(),
                .owner = worker.kept.allocator(),
            };

            inline for (comptime workflow.steps(.Analyze, kind, true)) |step| switch (step) {
                .Claim => if (!Schedule.transition(self.states, index, .Claim)) return,
                .ReadGrowth => {
                    // A speculative demand can replace its own growth views before the foreground adopts them.
                    const current = &self.bodies.units[index].growth;
                    growth = if (generated) current.* else try current.clone(input.scratch);
                    input.growth = &growth;
                },
                .AnalyzeDeferred, .AnalyzePlan => result = try analyze(step == .AnalyzeDeferred, input),
                .Publish => self.results[index] = @unionInit(Result, @tagName(kind), result),
                .Complete => _ = Schedule.transition(self.states, index, .Complete),
                else => unreachable,
            };
        }

        fn analyze(comptime deferred: bool, input: compute.Input) Error!Found(kind) {
            const result = try compute.run(kind, deferred, input);
            const record = result.record;

            return switch (kind) {
                .settled => .{ .passed = record.passed, .output = record.output, .reads = result.reads },
                .demanded => .{
                    .marks = record.marks,
                    .grew = record.grew,
                    .growth = .{ .normalized = record.normalized, .renewed = record.renewed },
                    .reads = result.reads,
                },
                .planned => record.plan(),
            };
        }
    };
}
