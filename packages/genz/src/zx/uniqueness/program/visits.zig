const std = @import("std");
const Context = @import("host.zig").Context;
const Function = @import("../function.zig");
const Growth = @import("../growth.zig");
const Plan = Function.Plan;
const Feedback = @import("../work/round.zig").Feedback;
const Error = std.mem.Allocator.Error;

pub fn settle(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Feedback {
    const rounds = &ctx.rounds.?;
    const unit = ctx.units[index].?;
    const recalled = (try ctx.replay.recall(.settled, index)) orelse try ctx.memo.getSettled(ctx.summaries, unit.state(index));
    const early = try rounds.ahead.take(.settled, index);
    const known = recalled orelse if (early) |found| try ctx.memo.putSettled(ctx.memo.key, found.passed, found.output) else null;
    var changed: []const u64 = undefined;

    const settled = if (known) |settled| replayed: {
        changed = try Function.replay(round.allocator(), ctx.summaries, settled.passed);

        break :replayed settled;
    } else analyzed: {
        var analysis = try unit.initialize(round.allocator(), rounds.ahead.kept(), ctx.program.functions, ctx.slots, ctx.summaries, null, false);
        const result = try analysis.settle(ctx.memo.arena.allocator(), if (index == ctx.program.functions.count()) 0 else ctx.summaries.output[index].len);
        changed = result.changed;

        break :analyzed try ctx.memo.putOwnedSettled(ctx.memo.key, result.passed, result.output);
    };

    try ctx.replay.met(.settled, index, settled, ctx.memo);

    return .{ .body = index, .changed = changed, .levels = settled.output };
}

pub fn demand(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Feedback {
    const rounds = &ctx.rounds.?;
    const unit = ctx.units[index].?;
    const state = unit.state(index);
    const recalled = (try ctx.replay.recall(.demanded, index)) orelse try ctx.memo.getDemanded(ctx.summaries, state);
    const early = try rounds.ahead.take(.demanded, index);
    var changed: []const u64 = undefined;

    const demanded = if (recalled) |demanded| replayed: {
        changed = try Function.replayMarks(round.allocator(), ctx.summaries, demanded.marks);

        try Growth.restore(&unit.growth, .{ .normalized = demanded.normalized, .renewed = demanded.renewed });

        break :replayed demanded;
    } else if (early) |found| ahead: {
        const rows = if (@import("genz_options").generated_analysis and found.grew)
            try found.growth.copy(ctx.memo.arena.allocator())
        else
            found.growth;

        try Growth.restore(&unit.growth, rows);

        changed = try Function.replayMarks(round.allocator(), ctx.summaries, found.marks);

        break :ahead try ctx.memo.putDemanded(ctx.memo.key, found.marks, &unit.growth, found.grew);
    } else analyzed: {
        var analysis = try unit.initialize(round.allocator(), rounds.ahead.kept(), ctx.program.functions, ctx.slots, ctx.summaries, null, false);
        const result = try analysis.demand(ctx.memo.arena.allocator());
        changed = result.changed;

        break :analyzed try ctx.memo.putOwnedDemanded(ctx.memo.key, result.marks, &unit.growth, analysis.grew);
    };

    try ctx.replay.met(.demanded, index, demanded, ctx.memo);

    return .{ .body = index, .changed = changed, .grew = demanded.grew };
}

pub fn plan(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Plan {
    const rounds = &ctx.rounds.?;
    const plan_owner = if (ctx.memo.persistent) ctx.memo.arena.allocator() else ctx.allocator;
    const unit = ctx.units[index].?;

    const recalled = if (ctx.memo.persistent)
        (try ctx.replay.recall(.planned, index)) orelse try ctx.memo.getPlanned(ctx.summaries, unit.state(index))

    else
        null;

    const early = try rounds.ahead.take(.planned, index);

    const built = if (recalled) |found| found.plan() else if (early) |found| try found.copy(plan_owner) else fresh: {
        _ = round.reset(.retain_capacity);

        var analysis = try unit.initialize(round.allocator(), ctx.temporary, ctx.program.functions, ctx.slots, ctx.summaries, null, false);

        break :fresh try analysis.plan(plan_owner);
    };

    return if (ctx.memo.persistent) stored: {
        const record = recalled orelse try ctx.memo.putOwnedPlan(ctx.memo.key, built);

        try ctx.replay.met(.planned, index, record, ctx.memo);

        break :stored try built.copy(ctx.allocator);
    } else built;
}
