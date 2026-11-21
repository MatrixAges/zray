const std = @import("std");
const analysis = @import("../root.zig");
const Context = @import("host.zig").Context;
const visits = @import("visit/seed.zig");
const Round = @import("../work/round.zig");
const PlanWriter = @import("visit/plan_writer.zig");
const Error = std.mem.Allocator.Error;

pub fn run(ctx: *Context) Error!analysis.Result {
    if (ctx.replay.trace != null) {
        const replayed = try @import("../replay/shortcut/seed.zig").run(ctx.allocator, ctx.workspace, ctx.temporary, ctx.slots, ctx.summaries, ctx.bodies, ctx.calls.active, ctx.memo, ctx.replay);

        if (replayed) |result| {
            ctx.release();

            return result;
        }
    }

    try ctx.open();

    var result: analysis.Result = .{ .functions = &.{}, .entry = .{ .flags = &.{} } };

    while (true) {
        const settled = try visitRound(ctx, .Settle, false, &result);
        const demanded = try visitRound(ctx, .Demand, settled.exhausted, &result);

        if (!demanded.grew) break;
    }

    _ = try visitRound(ctx, .Plan, false, &result);

    ctx.release();

    if (ctx.replay.recording != null) try ctx.commit();

    return result;
}

fn visitRound(ctx: *Context, comptime phase: Round.Phase, exhausted: bool, result: *analysis.Result) Error!Round.Outcome {
    const kind: analysis.Memo.Kind = switch (phase) {
        .Settle => .settled,
        .Demand => .demanded,
        .Plan => .planned,
        else => unreachable,
    };

    const rounds = &ctx.rounds.?;

    try rounds.work.prepare(ctx.summaries, ctx.calls.active, rounds.reverse.known, phase, exhausted);

    var round = std.heap.ArenaAllocator.init(ctx.workspace);

    defer round.deinit();
    rounds.ahead.begin(kind);
    defer rounds.ahead.finish();

    var plans = if (kind == .planned) try PlanWriter.init(ctx.allocator, ctx.calls.active) else {};

    const frame: Round.Frame = .{
        .active = ctx.calls.active,
        .outputs = ctx.summaries.output,
        .dirty = rounds.ahead.dirty,
        .callers = rounds.reverse.callers,
    };

    var feedback: ?Round.Feedback = null;

    while (true) {
        const claim = try rounds.work.advance(phase, &frame, feedback, ctx.replay.trace != null);

        if (claim.prefetch) try rounds.ahead.requestSeed(kind, ctx.memo, claim.pending);

        const index = switch (claim.visit) {
            .done => {
                if (kind == .planned) result.* = plans.result();

                return .{ .grew = claim.grew };
            },
            .exhausted => return .{ .exhausted = true },
            .body => |index| index,
        };

        if (kind != .planned) _ = round.reset(.retain_capacity);

        switch (kind) {
            .settled => feedback = try visits.settle(ctx, &round, index),
            .demanded => feedback = try visits.demand(ctx, &round, index),
            .planned => plans.putSeed(index, try visits.plan(ctx, &round, index)),
        }
    }
}
