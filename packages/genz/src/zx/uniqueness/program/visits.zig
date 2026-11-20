const std = @import("std");
const Context = @import("host.zig").Context;
const Function = @import("../function.zig");
const Plan = Function.Plan;
const Feedback = @import("../work/round.zig").Feedback;
const Error = std.mem.Allocator.Error;
const select = @import("visit/select.zig");
const applyDemand = @import("visit/demand.zig").apply;

pub fn settle(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Feedback {
    const rounds = &ctx.rounds.?;
    const unit = ctx.units[index].?;
    const recalled = (try ctx.replay.recall(.settled, index)) orelse try ctx.memo.getSettled(ctx.summaries, unit.state(index));
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
            var function = try unit.initialize(round.allocator(), rounds.ahead.kept(), ctx.program.functions, ctx.slots, ctx.summaries, null, false);
            const result = try function.settle(ctx.memo.arena.allocator(), if (index == ctx.program.functions.count()) 0 else ctx.summaries.output[index].len);
            changed = result.changed;

            break :analyzed try ctx.memo.putOwnedSettled(ctx.memo.key, result.passed, result.output);
        },
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
    const origin = select.choose(recalled != null, early != null);
    var changed: []const u64 = undefined;

    const demanded = switch (origin) {
        .Cached => replayed: {
            const record = recalled.?;
            changed = try applyDemand(round.allocator(), ctx.summaries, &unit.growth, .{ .normalized = record.normalized, .renewed = record.renewed }, record.marks, origin);

            break :replayed record;
        },
        .Ahead => ahead: {
            const found = early.?;

            const rows = if (@import("genz_options").generated_analysis and found.grew)
                try @import("../retain.zig").growth(ctx.memo.arena.allocator(), found.growth)
            else
                found.growth;

            changed = try applyDemand(round.allocator(), ctx.summaries, &unit.growth, rows, found.marks, origin);

            break :ahead try ctx.memo.putDemanded(ctx.memo.key, found.marks, &unit.growth, found.grew);
        },
        .Analyze => analyzed: {
            var function = try unit.initialize(round.allocator(), rounds.ahead.kept(), ctx.program.functions, ctx.slots, ctx.summaries, null, false);
            const result = try function.demand(ctx.memo.arena.allocator());
            changed = result.changed;

            break :analyzed try ctx.memo.putOwnedDemanded(ctx.memo.key, result.marks, &unit.growth, function.grew);
        },
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
    const origin = select.choose(recalled != null, early != null);

    const built = switch (origin) {
        .Cached => recalled.?.plan(),
        .Ahead => try early.?.copy(plan_owner),
        .Analyze => fresh: {
            _ = round.reset(.retain_capacity);

            var function = try unit.initialize(round.allocator(), ctx.temporary, ctx.program.functions, ctx.slots, ctx.summaries, null, false);

            break :fresh try function.plan(plan_owner);
        },
    };

    return if (ctx.memo.persistent) stored: {
        const record = if (origin == .Cached) recalled.? else try ctx.memo.putOwnedPlan(ctx.memo.key, built);

        try ctx.replay.met(.planned, index, record, ctx.memo);

        break :stored try built.copy(ctx.allocator);
    } else built;
}
