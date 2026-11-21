const std = @import("std");
const Context = @import("../host.zig").Context;
const Function = @import("../../function.zig");
const Plan = Function.Plan;
const Feedback = @import("../../work/round.zig").Feedback;
const Error = std.mem.Allocator.Error;
const select = @import("select.zig");
const Growth = @import("../../growth.zig");

fn applyDemand(ctx: *Context, allocator: std.mem.Allocator, growth: *Growth.Store, rows: Growth.Rows, marks: []const Function.Mark, origin: select.Origin) Error![]const u64 {
    if (origin == .Ahead) try Growth.restore(growth, rows);

    const changed = try Function.replayMarksSeed(allocator, ctx.summaries, marks);

    if (origin == .Cached) try Growth.restore(growth, rows);

    return changed;
}

pub fn settle(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Feedback {
    const rounds = &ctx.rounds.?;
    const recalled = (try ctx.replay.recall(.settled, index)) orelse try ctx.memo.getSettled(ctx.summaries, ctx.bodies.state(ctx.summaries, index));
    const early = try rounds.ahead.take(.settled, index);
    const origin = select.choose(recalled != null, early != null);
    var changed: []const u64 = undefined;

    const settled = switch (origin) {
        .Cached, .Ahead => replayed: {
            const record = if (origin == .Cached) recalled.? else try ctx.memo.putSettled(ctx.memo.key, early.?.passed, early.?.output);
            changed = try Function.replay(round.allocator(), ctx.summaries, record.passed);

            break :replayed record;
        },
        .Analyze => analyzed: {
            var function = try ctx.bodies.analyze(round.allocator(), rounds.ahead.kept(), ctx.slots, ctx.summaries, index, null, false);
            const result = try function.settle(ctx.memo.arena.allocator(), if (index == ctx.bodies.program.functions.count()) 0 else ctx.summaries.output[index].len);
            changed = result.changed;

            break :analyzed try ctx.memo.putOwnedSettled(ctx.memo.key, result.passed, result.output);
        },
    };

    try ctx.replay.met(.settled, index, settled, ctx.memo);

    return .{ .body = index, .changed = changed, .levels = settled.output };
}

pub fn demand(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Feedback {
    const rounds = &ctx.rounds.?;
    const state = ctx.bodies.state(ctx.summaries, index);
    const growth = &ctx.bodies.units[index].growth;
    const recalled = (try ctx.replay.recall(.demanded, index)) orelse try ctx.memo.getDemanded(ctx.summaries, state);
    const early = try rounds.ahead.take(.demanded, index);
    const origin = select.choose(recalled != null, early != null);
    var changed: []const u64 = undefined;

    const demanded = switch (origin) {
        .Cached => replayed: {
            const record = recalled.?;
            changed = try applyDemand(ctx, round.allocator(), growth, .{ .normalized = record.normalized, .renewed = record.renewed }, record.marks, origin);

            break :replayed record;
        },
        .Ahead => ahead: {
            const found = early.?;

            changed = try applyDemand(ctx, round.allocator(), growth, found.growth, found.marks, origin);

            break :ahead try ctx.memo.putDemanded(ctx.memo.key, found.marks, growth, found.grew);
        },
        .Analyze => analyzed: {
            var function = try ctx.bodies.analyze(round.allocator(), rounds.ahead.kept(), ctx.slots, ctx.summaries, index, null, false);
            const result = try function.demand(ctx.memo.arena.allocator());
            changed = result.changed;

            break :analyzed try ctx.memo.putOwnedDemanded(ctx.memo.key, result.marks, growth, function.grew);
        },
    };

    try ctx.replay.met(.demanded, index, demanded, ctx.memo);

    return .{ .body = index, .changed = changed, .grew = demanded.grew };
}

pub fn plan(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Plan {
    const rounds = &ctx.rounds.?;
    const plan_owner = if (ctx.memo.persistent) ctx.memo.arena.allocator() else ctx.allocator;

    const recalled = if (ctx.memo.persistent)
        (try ctx.replay.recall(.planned, index)) orelse try ctx.memo.getPlanned(ctx.summaries, ctx.bodies.state(ctx.summaries, index))

    else
        null;

    const early = try rounds.ahead.take(.planned, index);
    const origin = select.choose(recalled != null, early != null);

    const built = switch (origin) {
        .Cached => recalled.?.plan(),
        .Ahead => try early.?.copy(plan_owner),
        .Analyze => fresh: {
            _ = round.reset(.retain_capacity);

            var function = try ctx.bodies.analyze(round.allocator(), ctx.temporary, ctx.slots, ctx.summaries, index, null, false);

            break :fresh try function.plan(plan_owner);
        },
    };

    return if (ctx.memo.persistent) stored: {
        const record = if (origin == .Cached) recalled.? else try ctx.memo.putOwnedPlan(ctx.memo.key, built);

        try ctx.replay.met(.planned, index, record, ctx.memo);

        break :stored try built.copy(ctx.allocator);
    } else built;
}
