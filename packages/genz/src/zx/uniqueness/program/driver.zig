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
pub const Api = @import("execution_abi").layouts.@"zig:ownership_host";
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
        .frame = @ptrCast(&frame),
        .persistent = ctx.memo.persistent,
        .recording = ctx.memo.record_trace,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    try program.executeIn(empty.allocator(), &input);

    return frame.result;
}

fn borrow(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}

fn close(self: *Self) void {
    switch (self.active) {
        .none => {},
        .round => |*round| round.close(self.ctx),
        .replay => |*replay| replay.close(),
    }

    self.active = .none;
}

pub fn prepareOwnershipStorage(handle: *anyopaque) Error!void {
    const self = borrow(handle);
    const input = &self.preparation;
    const ctx = self.ctx;
    const prepared = try @import("../summaries/storage.zig").prepare(ctx.temporary, input.summary_allocator, input.program, input.basis);

    ctx.calls = prepared.calls;
    ctx.summaries.* = prepared.summaries;
    ctx.summaries.return_allocations = input.return_allocations;
}

pub fn prepareOwnershipIdentities(handle: *anyopaque) Error!void {
    const self = borrow(handle);
    const input = &self.preparation;
    const ctx = self.ctx;

    self.shared_identity = Identity.program(input.program.*, input.basis, input.return_allocations);
    self.identities = try Identity.bodies(ctx.temporary, input.program, ctx.calls.active, &self.shared_identity, input.basis.contents);
}

pub fn prepareOwnershipReplay(handle: *anyopaque) Error!void {
    const self = borrow(handle);
    const ctx = self.ctx;
    const memo = ctx.memo;
    const previous = if (memo.trace) |*trace| trace else null;
    const key = Identity.combine(&self.shared_identity, std.mem.sliceAsBytes(ctx.exported));
    ctx.replay.* = try .init(ctx.temporary, memo.arena.child_allocator, previous, key, self.identities, ctx.calls.callees);
}

pub fn prepareOwnershipBodies(handle: *anyopaque) Error!void {
    const self = borrow(handle);
    const ctx = self.ctx;

    ctx.bodies.* = try Bodies.init(ctx.temporary, self.preparation.program, ctx.calls.callees, self.identities);
}

pub fn prepareOwnershipWorkers(handle: *anyopaque) Error!void {
    const self = borrow(handle);

    self.ahead = try self.ctx.prepareWorkers();
}

pub fn prepareOwnershipQueue(handle: *anyopaque) Error!void {
    const self = borrow(handle);
    const ctx = self.ctx;
    const prepared = try Analysis.Work.open(ctx.workspace, ctx.roundMemory(), ctx.calls.callees, ctx.exported);
    ctx.rounds = .{ .work = prepared.work, .reverse = prepared.reverse, .ahead = self.ahead };
}

pub fn bindOwnershipMemoRows(handle: *anyopaque) void {
    const ctx = borrow(handle).ctx;

    ctx.rounds.?.ahead.memo_rows.init(ctx.bodies);
}

pub fn releaseOwnership(handle: *anyopaque) void {
    borrow(handle).ctx.release();
}

pub fn commitOwnership(handle: *anyopaque) Error!void {
    try borrow(handle).ctx.commit();
}

pub fn beginOwnershipRound(handle: *anyopaque, kind: Api.RoundKind, exhausted: bool) Error!void {
    const self = borrow(handle);

    self.active = .{ .round = .{ .arena = .init(self.ctx.workspace) } };

    try self.active.round.open(self.ctx, kind, exhausted);
}

pub fn claimOwnershipBody(handle: *anyopaque, kind: Api.RoundKind) Error!?u64 {
    const self = borrow(handle);

    return self.active.round.claim(self.ctx, kind);
}

pub fn visitOwnershipBody(handle: *anyopaque, kind: Api.RoundKind, body: u64) Error!void {
    const self = borrow(handle);

    return self.active.round.visit(self.ctx, kind, @intCast(body));
}

pub fn finishOwnershipRound(handle: *anyopaque, publish: bool) void {
    const self = borrow(handle);

    if (publish) self.result = self.active.round.plans.result();

    self.close();
}

pub fn ownershipRoundOutcome(handle: *anyopaque) Api.RoundOutcome {
    return borrow(handle).active.round.outcome;
}

pub fn beginOwnershipReplay(handle: *anyopaque) bool {
    const self = borrow(handle);

    if (self.ctx.replay.trace == null) return false;

    self.active = .{ .replay = .init(self.ctx.workspace) };

    return true;
}

pub fn scanOwnershipReplay(handle: *anyopaque, phase: Api.ReplayPhase, recovered: ?u32) Error!Api.ReplayPhase {
    const self = borrow(handle);

    return self.active.replay.advance(self.ctx, phase, recovered);
}

pub fn recoverOwnershipVisit(handle: *anyopaque, phase: Api.ReplayPhase) Error!u32 {
    const self = borrow(handle);

    return self.active.replay.recover(self.ctx, phase);
}

pub fn publishOwnershipReplay(handle: *anyopaque) Error!void {
    const self = borrow(handle);

    self.result = try self.active.replay.publish(self.ctx);
}

pub fn finishOwnershipReplay(handle: *anyopaque) void {
    borrow(handle).close();
}
