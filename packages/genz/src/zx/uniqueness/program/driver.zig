const std = @import("std");
const ir = @import("zx").ir;
const Analysis = @import("../root.zig");
const Ahead = @import("../ahead.zig");
const Identity = @import("../identity.zig");
const Trace = @import("../trace.zig");
const Bodies = @import("bodies.zig");
const Context = @import("host.zig").Context;
const Result = Analysis.Result;
const Round = @import("driver/round.zig");
const Replay = @import("../replay/shortcut/frame.zig");
const program = @import("generated_uniqueness_program");
const Store = std.meta.Child(@FieldType(program.zx_pending, "store_0"));
const Exchange = std.meta.Child(Store);
const Request = std.meta.Child(std.meta.Child(@FieldType(Exchange, "request")));
pub const RoundKind = std.meta.Child(@FieldType(Request, "kind"));
pub const ReplayPhase = @FieldType(Exchange, "phase");
const Error = std.mem.Allocator.Error;
const Self = @This();

pub const Preparation = struct {
    program: *const ir.Program,
    basis: *const Analysis.Basis,
    return_allocations: []const bool,
    summary_allocator: std.mem.Allocator,
};

ctx: *Context,
preparation: Preparation,
shared_identity: Trace.Digest = undefined,
identities: []const Trace.Digest = &.{},
ahead: Ahead = undefined,
result: Result = .{ .functions = &.{}, .entry = .{ .flags = &.{} } },
active: union(enum) { none, round: Round, replay: Replay } = .none,
pub fn run(ctx: *Context, preparation: Preparation) Error!Result {
    var frame: Self = .{ .ctx = ctx, .preparation = preparation };

    defer frame.close();

    const input: std.meta.Child(program.Input) = .{
        .persistent = ctx.memo.persistent,
        .recording = ctx.memo.record_trace,
    };

    const commit = execute: {
        var scratch = std.heap.ArenaAllocator.init(ctx.workspace);
        var buffer: [std.heap.page_size_min]u8 = undefined;
        var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

        defer scratch.deinit();

        const temporary = memory.allocator();

        var store: Store = &.{
            .request = null,
            .available = false,
            .body = null,
            .grew = false,
            .exhausted = false,
            .phase = .Start,
            .recovered = null,
        };

        var host: Host = .{ .frame = &frame, .temporary = temporary, .store_0 = &store };

        break :execute program.executeIn(temporary, &input, &host) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };
    };

    ctx.release();

    if (commit) try ctx.commit();

    return frame.result;
}

const Host = struct {
    frame: *Self,
    temporary: std.mem.Allocator,
    store_0: *Store,
    pub fn commit(host: *Host, pending: anytype) Error!void {
        const exchange = pending.store_0 orelse return;
        const effect = exchange.request.?;
        const frame = host.frame;
        const ctx = frame.ctx;

        const reply = switch (effect.step) {
            .PrepareReplay, .ClaimBody, .ScanReplay, .RecoverVisit => try host.temporary.create(Exchange),
            else => null,
        };

        var next = exchange.*;

        switch (effect.step) {
            .PrepareStorage => try frame.prepareStorage(),
            .PrepareIdentities => try frame.prepareIdentities(),
            .PrepareReplay => next.available = try frame.prepareReplay(),
            .PrepareBodies => ctx.bodies.* = try Bodies.init(ctx.temporary, frame.preparation.program, ctx.calls.callees, frame.identities),
            .PrepareWorkers => frame.ahead = try ctx.prepareWorkers(),
            .PrepareQueue => try frame.prepareQueue(),
            .BindMemoRows => ctx.rounds.?.ahead.memo_rows.init(ctx.bodies),
            .BeginRound => try frame.beginRound(effect.kind.?, effect.exhausted.?),
            .ClaimBody => {
                const claim = try frame.active.round.claim(ctx, effect.kind.?);

                next.body = claim.body;
                next.grew = claim.grew;
                next.exhausted = claim.exhausted;
            },
            .VisitBody => try frame.active.round.visit(ctx, effect.kind.?, @intCast(effect.body.?)),
            .PublishRound => frame.result = frame.active.round.plans.result(),
            .FinishRound => frame.close(),
            .BeginReplay => frame.active = .{ .replay = .init(ctx.workspace) },
            .ScanReplay => next.phase = try frame.active.replay.advance(ctx, effect.phase.?, effect.recovered),
            .RecoverVisit => next.recovered = try frame.active.replay.recover(ctx, effect.phase.?),
            .PublishReplay => frame.result = try frame.active.replay.publish(ctx),
            .FinishReplay => frame.close(),
        }

        if (reply) |saved| {
            saved.* = next;
            host.store_0.* = saved;
        } else {
            host.store_0.* = exchange;
        }
    }
};

fn close(self: *Self) void {
    switch (self.active) {
        .none => {},
        .round => |*round| round.close(self.ctx),
        .replay => |*replay| replay.close(),
    }

    self.active = .none;
}

fn prepareStorage(self: *Self) Error!void {
    const input = &self.preparation;
    const ctx = self.ctx;
    const prepared = try @import("../summaries/storage.zig").prepare(ctx.temporary, input.summary_allocator, input.program, input.basis);

    ctx.calls = prepared.calls;
    ctx.summaries.* = prepared.summaries;
    ctx.summaries.return_allocations = input.return_allocations;
}

fn prepareIdentities(self: *Self) Error!void {
    const input = &self.preparation;
    const ctx = self.ctx;

    self.shared_identity = Identity.program(input.program.*, input.basis, input.return_allocations);
    self.identities = try Identity.bodies(ctx.temporary, input.program, ctx.calls.active, &self.shared_identity, input.basis.contents);
}

fn prepareReplay(self: *Self) Error!bool {
    const ctx = self.ctx;
    const memo = ctx.memo;
    const previous = if (memo.trace) |*trace| trace else null;
    const key = Identity.combine(&self.shared_identity, std.mem.sliceAsBytes(ctx.exported));
    ctx.replay.* = try .init(ctx.temporary, memo.arena.child_allocator, previous, key, self.identities, ctx.calls.callees);

    return ctx.replay.trace != null;
}

fn prepareQueue(self: *Self) Error!void {
    const ctx = self.ctx;
    const prepared = try Analysis.Work.open(ctx.workspace, ctx.roundMemory(), ctx.calls.callees, ctx.exported);
    ctx.rounds = .{ .work = prepared.work, .reverse = prepared.reverse, .ahead = self.ahead };
}

fn beginRound(self: *Self, kind: RoundKind, exhausted: bool) Error!void {
    self.active = .{ .round = .{ .arena = .init(self.ctx.workspace) } };

    try self.active.round.open(self.ctx, kind, exhausted);
}
