const std = @import("std");
const ir = @import("zx").ir;
const analysis = @import("../root.zig");
const Ahead = @import("../ahead.zig");
const Pool = @import("../pool.zig");
const Topology = @import("../topology.zig");
const Replay = @import("../trace.zig").Replay;
const generated = @import("genz_options").generated_analysis;
const Error = std.mem.Allocator.Error;
const visits = if (generated) @import("visits.zig") else @import("visit/seed.zig");
const Bodies = @import("bodies.zig");
const transition = @import("transition.zig");
const Round = @import("../work/round.zig");
const Phase = Round.Phase;
const PlanWriter = @import("visit/plan_writer.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    slots: analysis.Slots,
    summaries: *analysis.Summaries,
    bodies: *const Bodies,
    calls: Topology.Calls,
    exported: []const ir.FunctionId,
    memo: *analysis.Memo,
    replay: *Replay,
    concurrent: bool,
    round_memory: ?std.heap.ArenaAllocator = null,
    pool: ?Pool = null,
    rounds: ?Rounds = null,
    const Rounds = struct {
        work: analysis.Work,
        reverse: Topology.Plan,
        ahead: Ahead,
    };
    pub fn run(self: *Context) Error!analysis.Result {
        errdefer self.release();

        var result = analysis.Result{ .functions = &.{}, .entry = .{ .flags = &.{} } };
        var step: transition.Step = .Start;
        var condition = self.replay.trace != null;

        while (true) {
            step = transition.next(step, condition);

            condition = switch (step) {
                .Start => unreachable,
                .Replay => replayed: {
                    const found = if (generated)
                        try @import("../replay/shortcut/verify.zig").run(self)
                    else
                        try @import("../replay/shortcut/seed.zig").run(self.allocator, self.workspace, self.temporary, self.slots, self.summaries, self.bodies, self.calls.active, self.memo, self.replay);

                    result = found orelse break :replayed false;

                    break :replayed true;
                },
                .Open => opened: {
                    try self.open();

                    break :opened false;
                },
                .Settle => (try self.visitRound(.Settle, false, &result)).exhausted,
                .Demand, .ConservativeDemand => (try self.visitRound(.Demand, step == .ConservativeDemand, &result)).grew,
                .Plan => planned: {
                    _ = try self.visitRound(.Plan, false, &result);

                    break :planned false;
                },
                .Release => released: {
                    self.release();

                    break :released self.replay.recording != null;
                },
                .ReleaseReused => {
                    self.release();

                    return result;
                },
                .Commit => {
                    try self.commit();

                    return result;
                },
                .Done => return result,
            };
        }
    }

    pub fn roundMemory(self: *Context) std.mem.Allocator {
        if (self.round_memory == null) self.round_memory = .init(self.workspace);

        return self.round_memory.?.allocator();
    }
    fn open(self: *Context) Error!void {
        const memory = self.roundMemory();
        self.pool = try Pool.init(memory, self.concurrent);
        const ahead = try Ahead.init(memory, &self.pool.?, self.slots, self.summaries, self.bodies, self.calls.recursive);

        const prepared = if (generated)
            try analysis.Work.open(self.workspace, memory, self.calls.callees, self.exported)

        else seed: {
            const reverse = try Topology.buildSeed(memory, self.calls.callees, self.exported);
            const work = try analysis.Work.init(self.workspace, self.calls.active.len);

            break :seed .{ .work = work, .reverse = reverse };
        };

        self.rounds = .{
            .work = prepared.work,
            .reverse = prepared.reverse,
            .ahead = ahead,
        };

        if (generated) self.rounds.?.ahead.memo_rows.init(self.bodies);
    }

    fn release(self: *Context) void {
        if (self.rounds) |*rounds| rounds.work.deinit();
        if (self.pool) |*pool| pool.deinit();
        if (self.round_memory) |*memory| memory.deinit();

        self.rounds = null;
        self.pool = null;
        self.round_memory = null;
    }

    fn visitRound(self: *Context, comptime phase: Phase, exhausted: bool, result: *analysis.Result) Error!Round.Outcome {
        const kind: analysis.Memo.Kind = comptime switch (phase) {
            .Settle => .settled,
            .Demand => .demanded,
            .Plan => .planned,
            else => unreachable,
        };

        const rounds = &self.rounds.?;

        try rounds.work.prepare(self.summaries, self.calls.active, rounds.reverse.known, phase, exhausted);

        var round = std.heap.ArenaAllocator.init(self.workspace);

        defer round.deinit();
        rounds.ahead.begin(kind);
        defer rounds.ahead.finish();

        var plans = if (kind == .planned) try PlanWriter.init(self.allocator, self.calls.active) else {};

        const frame = Round.Frame{
            .active = self.calls.active,
            .outputs = self.summaries.output,
            .dirty = rounds.ahead.dirty,
            .callers = rounds.reverse.callers,
            .plans = if (generated and kind == .planned) plans.target() else null,
        };

        var feedback: ?Round.Feedback = null;
        var completed_plan: if (generated and kind == .planned) analysis.Plan else void = undefined;

        while (true) {
            const following = self.replay.trace != null;

            const claim = if (generated)
                try rounds.work.advance(kind, phase, &frame, feedback, following, &rounds.ahead, self.memo)
            else
                try rounds.work.advance(phase, &frame, feedback, following);

            if (!generated and claim.prefetch) try rounds.ahead.requestSeed(kind, self.memo, claim.pending);

            const index = switch (claim.visit) {
                .done => {
                    if (kind == .planned) result.* = plans.result();

                    return .{ .grew = claim.grew };
                },
                .exhausted => return .{ .exhausted = true },
                .body => |index| index,
            };

            // The previous visit's changed rows are borrowed until advance has published them.
            if (!generated and kind != .planned) _ = round.reset(.retain_capacity);

            switch (kind) {
                .settled => feedback = try visits.settle(self, &round, index),
                .demanded => feedback = try visits.demand(self, &round, index),
                .planned => {
                    const value = try visits.plan(self, &round, index);

                    if (generated) {
                        completed_plan = value;
                        feedback = .{ .body = index, .changed = &.{}, .plan = std.mem.asBytes(&completed_plan) };
                    } else {
                        plans.putSeed(index, value);
                    }
                },
            }
        }
    }

    fn commit(self: *Context) Error!void {
        const trace = try self.replay.finish();

        if (self.memo.trace) |*previous| previous.deinit();

        self.memo.trace = trace;
    }
};
