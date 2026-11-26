const std = @import("std");
const ir = @import("zx").ir;
const Analysis = @import("../root.zig");
const Identity = @import("../identity.zig");
const Trace = @import("../trace.zig");
const Bodies = @import("bodies.zig");
const Context = @import("host.zig").Context;
const Result = Analysis.Result;
const Round = @import("driver/round.zig");
const Replay = @import("../replay/shortcut/frame.zig");
const Error = std.mem.Allocator.Error;

pub const Preparation = struct {
    program: *const ir.Program,
    basis: *const Analysis.Basis,
    return_allocations: []const bool,
    summary_allocator: std.mem.Allocator,
};

pub fn run(ctx: *Context, preparation: Preparation) Error!Result {
    const prepared = try @import("../summaries/storage.zig").prepare(ctx.temporary, preparation.summary_allocator, preparation.program, preparation.basis);
    ctx.calls = prepared.calls;
    ctx.summaries.* = prepared.summaries;
    ctx.summaries.return_allocations = preparation.return_allocations;
    var identities: []const Trace.Digest = &.{};

    if (ctx.memo.persistent) {
        const shared_identity = Identity.program(preparation.program.*, preparation.basis, preparation.return_allocations);
        identities = try Identity.bodies(ctx.temporary, preparation.program, ctx.calls.active, &shared_identity, preparation.basis.contents);

        if (ctx.memo.record_trace) {
            const memo = ctx.memo;
            const previous = if (memo.trace) |*trace| trace else null;
            const key = Identity.combine(&shared_identity, std.mem.sliceAsBytes(ctx.exported));
            ctx.replay.* = try .init(ctx.temporary, memo.arena.child_allocator, previous, key, identities, ctx.calls.callees);
        }
    }

    ctx.bodies.* = try Bodies.init(ctx.temporary, preparation.program, ctx.calls.callees, identities);
    var reused = false;
    var result: Result = .{ .functions = &.{}, .entry = .{ .flags = &.{} } };

    if (try attemptReplay(ctx)) |replayed| {
        result = replayed;
        reused = true;
    } else {
        const ahead = try ctx.prepareWorkers();
        const queue = try Analysis.Work.open(ctx.workspace, ctx.roundMemory(), ctx.calls.callees, ctx.exported);

        ctx.rounds = .{ .work = queue.work, .reverse = queue.reverse, .ahead = ahead };

        ctx.rounds.?.ahead.memo_rows.init(ctx.bodies);

        while (true) {
            const settled = try runRound(ctx, .Settle, false);
            const demanded = try runRound(ctx, .Demand, settled.outcome == .Exhausted);

            if (demanded.outcome != .Grew) break;
        }

        const planned = try runRound(ctx, .Plan, false);

        result = planned.result;
    }

    ctx.release();

    if (ctx.memo.persistent and ctx.memo.record_trace and !reused) try ctx.commit();

    return result;
}

fn attemptReplay(ctx: *Context) Error!?Result {
    if (ctx.replay.trace == null) return null;

    var replay: Replay = .init(ctx.workspace);

    defer replay.close();

    var phase: Replay.Phase = .start;
    var recovered: ?u32 = null;

    while (phase != .done and phase != .reject) {
        phase = try replay.advance(ctx, phase, recovered);

        if (phase != .done and phase != .reject) recovered = try replay.recover(ctx, phase);
    }

    if (phase != .done) return null;

    return try replay.publish(ctx);
}

const RoundResult = struct {
    outcome: Round.Outcome,
    result: Result,
};

fn runRound(ctx: *Context, comptime kind: Round.Kind, exhausted: bool) Error!RoundResult {
    var round: Round = .{ .arena = .init(ctx.workspace) };

    defer round.close(ctx);

    try round.open(ctx, kind, exhausted);

    while (try round.claim(ctx, kind)) |body| {
        try round.visit(ctx, kind, @intCast(body));
    }

    const result = if (kind == .Plan and round.outcome != .Exhausted)
        round.plans.result()

    else
        Result{ .functions = &.{}, .entry = .{ .flags = &.{} } };

    return .{ .outcome = round.outcome, .result = result };
}
