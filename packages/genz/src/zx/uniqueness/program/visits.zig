const std = @import("std");
const zx = @import("zx");
const Context = @import("host.zig").Context;
const Ahead = @import("../ahead.zig");
const Function = @import("../function.zig");
const Memo = @import("../memo.zig");
const Round = @import("../work/round.zig");
const select = @import("visit/select.zig");
const compute = @import("visit/compute.zig");
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
    var visit: Visit(kind) = .{ .ctx = ctx, .round = round, .index = index };

    try visit.execute(persistent, null);

    switch (select.choose(visit.cached != null, visit.ahead != null)) {
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
        fn execute(self: *Self, comptime persistent: bool, comptime origin: ?select.Origin) Error!void {
            const steps = comptime zx.staticSequence(sequence, &.{
                .phase = phase,
                .origin = origin,
                .persistent = persistent,
            });

            inline for (steps) |step| switch (step) {
                .Recall => self.cached = try self.ctx.replay.recall(kind, self.index),
                .ReadMemoOnMiss => if (self.cached == null) {
                    self.cached = try self.lookup();
                },
                .TakeAhead => self.ahead = try self.ctx.rounds.?.ahead.take(kind, self.index),
                .UseCached => self.record = self.cached.?,
                .AdoptAhead => try self.adopt(persistent),
                .ResetScratch => _ = self.round.reset(.retain_capacity),
                .Analyze => try self.analyze(persistent),
                .Apply => try self.apply(origin.?),
                .SaveBorrowed => try self.save(false),
                .SaveOwned => try self.save(true),
                .RecordTrace => try self.ctx.replay.met(kind, self.index, self.record, self.ctx.memo),
                .RetainOutput => self.record = Memo.Planned.fromPlan(try self.record.plan().copy(self.ctx.allocator)),
            };
        }

        fn lookup(self: *Self) Error!?Memo.Result(kind) {
            const ctx = self.ctx;
            const state = ctx.bodies.state(ctx.summaries, self.index);

            const get = comptime switch (kind) {
                .settled => Memo.getSettled,
                .demanded => Memo.getDemanded,
                .planned => Memo.getPlanned,
            };

            return get(ctx.memo, ctx.summaries, state);
        }
        fn owner(self: *Self, comptime persistent: bool) std.mem.Allocator {
            return if (persistent) self.ctx.memo.arena.allocator() else self.ctx.allocator;
        }
        fn adopt(self: *Self, comptime persistent: bool) Error!void {
            const found = self.ahead.?;

            self.record = switch (kind) {
                .settled => .{ .passed = found.passed, .output = found.output },
                .demanded => adopted: {
                    const growth = if (found.grew)
                        try @import("../retain.zig").growth(self.owner(persistent), found.growth)
                    else
                        found.growth;

                    break :adopted .{ .marks = found.marks, .normalized = growth.normalized, .renewed = growth.renewed, .grew = found.grew };
                },
                .planned => Memo.Planned.fromPlan(try found.copy(self.owner(persistent))),
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
                .lasting = if (kind == .planned) ctx.temporary else ctx.rounds.?.ahead.kept(),
                .owner = self.owner(persistent),
            });

            self.record = result.record;
            self.changed = result.changed;
        }

        fn apply(self: *Self, origin: select.Origin) Error!void {
            const ctx = self.ctx;
            const scratch = self.round.allocator();
            const record = self.record;

            self.changed = switch (kind) {
                .settled => try Function.replay(scratch, ctx.summaries, record.passed),
                .demanded => try @import("visit/demand.zig").apply(
                    scratch,
                    ctx.summaries,
                    &ctx.bodies.units[self.index].growth,
                    .{ .normalized = record.normalized, .renewed = record.renewed },
                    record.marks,
                    origin,
                ),
                .planned => unreachable,
            };
        }
        fn save(self: *Self, comptime owned: bool) Error!void {
            self.record = try self.ctx.memo.putVisit(kind, self.record, owned);
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
