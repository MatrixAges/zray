const std = @import("std");
const ir = @import("zx").ir;
const analysis = @import("../root.zig");
const Ahead = @import("../ahead.zig");
const Pool = @import("../pool.zig");
const Topology = @import("../topology.zig");
const Replay = @import("../trace.zig").Replay;
const generated = @import("genz_options").generated_analysis;
const Error = std.mem.Allocator.Error;
const visits = @import("visits.zig");
const Bodies = @import("bodies.zig");
const driver = if (generated) @import("generated_uniqueness_program") else void;
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
    pool: ?Pool = null,
    rounds: ?Rounds = null,
    const Rounds = struct {
        work: analysis.Work,
        reverse: Topology.Plan,
        ahead: Ahead,
    };
    pub fn run(self: *Context) Error!analysis.Result {
        defer {
            if (self.rounds) |*rounds| rounds.work.deinit();
            if (self.pool) |*pool| pool.deinit();
        }

        var result = analysis.Result{ .functions = &.{}, .entry = .{ .flags = &.{} } };
        var phase: Phase = .Start;
        var reused = false;
        var outcome: Round.Outcome = .{};

        while (true) {
            phase = self.next(phase, reused, outcome.grew);

            switch (phase) {
                .Start => unreachable,
                .Replay => {
                    if (try analysis.shortcut(self.allocator, self.workspace, self.temporary, self.slots, self.summaries, self.bodies, self.calls.active, self.memo, self.replay)) |found| {
                        result = found;
                        reused = true;
                    }
                },
                .Settle => {
                    if (self.rounds == null) try self.open();

                    outcome = try self.visitRound(.Settle, false, &result);
                },
                .Demand => outcome = try self.visitRound(.Demand, outcome.exhausted, &result),
                .Plan => outcome = try self.visitRound(.Plan, false, &result),
                .Commit => try self.commit(),
                .Done => return result,
            }
        }
    }

    fn next(self: *const Context, phase: Phase, reused: bool, grew: bool) Phase {
        const following = self.replay.trace != null;
        const recording = self.replay.recording != null;

        if (!generated) return switch (phase) {
            .Start => if (following) .Replay else .Settle,
            .Replay => if (reused) .Done else .Settle,
            .Settle => .Demand,
            .Demand => if (grew) .Settle else .Plan,
            .Plan => if (recording) .Commit else .Done,
            .Commit, .Done => .Done,
        };

        const input: std.meta.Child(driver.Input) = .{ .phase = phase, .following = following, .reused = reused, .grew = grew, .recording = recording };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return @import("zx").columns.invoke(driver.executeValue, empty.allocator(), &input) catch unreachable;
    }
    fn open(self: *Context) Error!void {
        self.pool = try Pool.init(self.temporary, self.concurrent);
        const ahead = try Ahead.init(self.temporary, &self.pool.?, self.slots, self.summaries, self.bodies, self.calls.recursive);
        const reverse = try Topology.build(self.temporary, self.calls.callees, self.exported);

        self.rounds = .{
            .work = try analysis.Work.init(self.workspace, self.calls.active.len),
            .reverse = reverse,
            .ahead = ahead,
        };
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

        var plans = if (kind == .planned) try PlanWriter.init(self.allocator, self.bodies.program.functions.count()) else {};

        const frame = Round.Frame{
            .active = self.calls.active,
            .outputs = self.summaries.output,
            .dirty = rounds.ahead.dirty,
            .callers = rounds.reverse.callers,
        };

        var feedback: ?Round.Feedback = null;

        while (true) {
            const claim = try rounds.work.advance(phase, &frame, feedback);

            if (self.replay.trace == null) try rounds.ahead.request(kind, self.memo, claim.pending);

            const index = switch (claim.visit) {
                .done => {
                    if (kind == .planned) result.* = plans.result();

                    return .{ .grew = claim.grew };
                },
                .exhausted => return .{ .exhausted = true },
                .body => |index| index,
            };

            // The previous visit's changed rows are borrowed until advance has published them.
            if (kind != .planned) _ = round.reset(.retain_capacity);

            switch (kind) {
                .settled => feedback = try visits.settle(self, &round, index),
                .demanded => feedback = try visits.demand(self, &round, index),
                .planned => plans.put(index, try visits.plan(self, &round, index)),
            }
        }
    }

    fn commit(self: *Context) Error!void {
        const trace = try self.replay.finish();

        if (self.memo.trace) |*previous| previous.deinit();

        self.memo.trace = trace;
    }
};
