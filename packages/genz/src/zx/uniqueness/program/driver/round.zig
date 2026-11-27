const std = @import("std");
const Memo = @import("../../memo.zig");
const Function = @import("../../function.zig");
const Context = @import("../host.zig").Context;
const Round = @import("../../work/round.zig");
const PlanWriter = @import("../visit/plan_writer.zig");
const visits = @import("../visits.zig");
const Api = @import("../driver.zig").Api;
const Error = std.mem.Allocator.Error;
const Self = @This();

arena: std.heap.ArenaAllocator,
started: bool = false,
plans: PlanWriter = undefined,
columns: Round.Frame = undefined,
feedback: ?Round.Feedback = null,
plan: Function.Plan = undefined,
claimed: Api.RoundClaim = undefined,
pub fn open(self: *Self, ctx: *Context, kind: Api.RoundKind, exhausted: bool) Error!void {
    const rounds = &ctx.rounds.?;

    switch (kind) {
        inline else => |phase| {
            try rounds.work.prepare(ctx.summaries, ctx.calls.active, rounds.reverse.known, @field(Round.Phase, @tagName(phase)), exhausted);

            rounds.ahead.begin(memoKind(phase));
        },
    }

    self.started = true;

    if (kind == .Plan) self.plans = try .init(ctx.allocator, ctx.calls.active);

    self.columns = .{
        .active = ctx.calls.active,
        .outputs = ctx.summaries.output,
        .dirty = rounds.ahead.dirty,
        .callers = rounds.reverse.callers,
        .plans = if (kind == .Plan) self.plans.target() else null,
    };
}

pub fn close(self: *Self, ctx: *Context) void {
    if (self.started) ctx.rounds.?.ahead.finish();

    self.arena.deinit();
}

pub fn claim(self: *Self, ctx: *Context, kind: Api.RoundKind) Error!*const Api.RoundClaim {
    const rounds = &ctx.rounds.?;
    const following = ctx.replay.trace != null;

    const next = switch (kind) {
        inline else => |phase| try rounds.work.advance(memoKind(phase), @field(Round.Phase, @tagName(phase)), &self.columns, self.feedback, following, &rounds.ahead, ctx.memo),
    };

    self.claimed = .{
        .body = switch (next.visit) {
            .body => |index| index,
            .done, .exhausted => null,
        },
        .grew = next.grew,
        .exhausted = next.visit == .exhausted,
    };

    return &self.claimed;
}

pub fn visit(self: *Self, ctx: *Context, kind: Api.RoundKind, body: usize) Error!void {
    self.feedback = switch (kind) {
        .Settle => try visits.settle(ctx, &self.arena, body),
        .Demand => try visits.demand(ctx, &self.arena, body),
        .Plan => planned: {
            self.plan = try visits.plan(ctx, &self.arena, body);

            break :planned .{ .body = body, .changed = &.{}, .plan = std.mem.asBytes(&self.plan) };
        },
    };
}

fn memoKind(comptime kind: Api.RoundKind) Memo.Kind {
    return switch (kind) {
        .Settle => .settled,
        .Demand => .demanded,
        .Plan => .planned,
    };
}
