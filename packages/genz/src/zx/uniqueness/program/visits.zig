const std = @import("std");
const zx = @import("zx");
const Context = @import("host.zig").Context;
const Ahead = @import("../ahead.zig");
const Function = @import("../function.zig");
const Memo = @import("../memo.zig");
const Round = @import("../work/round.zig");
const intake = @import("visit/intake.zig");
const compute = @import("visit/compute.zig");
const demand_visit = @import("visit/demand.zig");
const settle_visit = @import("visit/settlement.zig");
const adopt_plan = @import("visit/adopt_plan.zig");
const sequence = @import("generated_uniqueness_visit_sequence");
const Error = std.mem.Allocator.Error;

pub fn settle(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Round.Feedback {
    return run(.settled, true, ctx, round, index);
}

pub fn demand(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Round.Feedback {
    return run(.demanded, true, ctx, round, index);
}

pub fn plan(ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Function.Plan {
    return switch (ctx.memo.persistent) {
        inline else => |persistent| run(.planned, persistent, ctx, round, index),
    };
}

fn Output(comptime kind: Memo.Kind) type {
    return if (kind == .planned) Function.Plan else Round.Feedback;
}

fn run(comptime kind: Memo.Kind, comptime persistent: bool, ctx: *Context, round: *std.heap.ArenaAllocator, index: usize) Error!Output(kind) {
    const choice = try intake.run(kind, persistent, ctx, round, index);

    var visit: Visit(kind) = .{
        .ctx = ctx,
        .round = round,
        .index = index,
        .cached = choice.cached,
        .ahead = choice.ahead,
    };

    switch (choice.origin) {
        inline else => |origin| try visit.execute(persistent, origin),
    }

    return visit.output();
}

fn Visit(comptime kind: Memo.Kind) type {
    return struct {
        ctx: *Context,
        round: *std.heap.ArenaAllocator,
        index: usize,
        cached: ?Memo.Result(kind) = null,
        ahead: ?Ahead.Found(kind) = null,
        record: Memo.Result(kind) = undefined,
        changed: []const u64 = &.{},
        const Self = @This();

        const phase: Round.Phase = switch (kind) {
            .settled => .Settle,
            .demanded => .Demand,
            .planned => .Plan,
        };
        fn execute(self: *Self, comptime persistent: bool, comptime origin: intake.Origin) Error!void {
            const steps = comptime zx.staticSequence(sequence, &.{
                .phase = phase,
                .origin = origin,
                .persistent = persistent,
            });

            inline for (steps) |step| switch (step) {
                .UseCached => self.record = self.cached.?,
                .AdoptAhead => try self.adopt(persistent),
                .Analyze => try self.analyze(persistent),
                .Apply => try self.apply(),
                .RecordTrace => try self.ctx.replay.met(kind, self.index, self.record, self.ctx.memo),
                .RetainOutput => self.record = Memo.Planned.fromPlan(try self.record.plan().copy(self.ctx.allocator)),
            };
        }
        fn owner(self: *Self, comptime persistent: bool) std.mem.Allocator {
            return if (persistent) self.ctx.memo.arena.allocator() else self.ctx.allocator;
        }
        fn adopt(self: *Self, comptime persistent: bool) Error!void {
            const found = self.ahead.?;
            const ctx = self.ctx;
            const scratch = self.round.allocator();

            self.record = switch (kind) {
                .settled => settled: {
                    const result = try settle_visit.apply(scratch, ctx.summaries, &.{ .passed = found.passed, .output = found.output }, ctx.memo);
                    self.changed = result.changed;

                    break :settled result.stored.?;
                },
                .demanded => adopted: {
                    const growth = &ctx.bodies.units[self.index].growth;
                    const result = try demand_visit.apply(scratch, self.owner(persistent), ctx.summaries, growth, found.growth, found.marks, .Ahead, found.grew, ctx.memo);
                    self.changed = result.changed;

                    break :adopted result.stored.?;
                },
                .planned => try adopt_plan.run(self.owner(persistent), &found, if (persistent) ctx.memo else null),
            };
        }
        fn analyze(self: *Self, comptime persistent: bool) Error!void {
            const ctx = self.ctx;

            const result = try compute.run(kind, false, .{
                .bodies = ctx.bodies,
                .slots = ctx.slots,
                .summaries = ctx.summaries,
                .body = self.index,
                .growth = &ctx.bodies.units[self.index].growth,
                .scratch = self.round.allocator(),
                .lasting = if (kind == .planned) ctx.roundMemory() else ctx.rounds.?.ahead.kept(),
                .owner = self.owner(persistent),
                .memo = if (persistent) ctx.memo else null,
            });

            self.record = result.record;
            self.changed = result.changed;
        }
        fn apply(self: *Self) Error!void {
            const ctx = self.ctx;
            const scratch = self.round.allocator();
            const record = self.record;

            self.changed = switch (kind) {
                .settled => (try settle_visit.apply(scratch, ctx.summaries, &record, null)).changed,
                .demanded => (try demand_visit.apply(
                    scratch,
                    scratch,
                    ctx.summaries,
                    &ctx.bodies.units[self.index].growth,
                    .{ .normalized = record.normalized, .renewed = record.renewed },
                    record.marks,
                    .Cached,
                    false,
                    null,
                )).changed,
                .planned => unreachable,
            };
        }

        fn output(self: *const Self) Output(kind) {
            return switch (kind) {
                .settled => .{ .body = self.index, .changed = self.changed, .levels = self.record.output },
                .demanded => .{ .body = self.index, .changed = self.changed, .grew = self.record.grew },
                .planned => self.record.plan(),
            };
        }
    };
}
