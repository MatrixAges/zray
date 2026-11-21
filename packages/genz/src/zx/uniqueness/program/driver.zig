const std = @import("std");
const Context = @import("host.zig").Context;
const Result = @import("../root.zig").Result;
const Round = @import("driver/round.zig");
const Replay = @import("../replay/shortcut/frame.zig");
const program = @import("generated_uniqueness_program");
pub const Api = @import("ownership_abi").layouts.@"zig:ownership_host";
const Error = std.mem.Allocator.Error;
const Self = @This();

ctx: *Context,
result: Result = .{ .functions = &.{}, .entry = .{ .flags = &.{} } },

active: union(enum) { none, round: Round, replay: Replay } = .none,
pub fn run(ctx: *Context) Error!Result {
    var frame: Self = .{ .ctx = ctx };

    defer frame.close();

    const input: std.meta.Child(program.Input) = .{
        .frame = @ptrCast(&frame),
        .recording = ctx.replay.recording != null,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    try program.executeIn(empty.allocator(), &input);

    return frame.result;
}

fn borrow(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn close(self: *Self) void {
    switch (self.active) {
        .none => {},
        .round => |*round| round.close(self.ctx),
        .replay => |*replay| replay.close(),
    }

    self.active = .none;
}

pub fn openOwnership(handle: *const anyopaque) Error!void {
    try borrow(handle).ctx.open();
}

pub fn releaseOwnership(handle: *const anyopaque) void {
    borrow(handle).ctx.release();
}

pub fn commitOwnership(handle: *const anyopaque) Error!void {
    try borrow(handle).ctx.commit();
}

pub fn beginOwnershipRound(handle: *const anyopaque, kind: Api.RoundKind, exhausted: bool) Error!void {
    const self = borrow(handle);

    self.active = .{ .round = .{ .arena = .init(self.ctx.workspace) } };

    try self.active.round.open(self.ctx, kind, exhausted);
}

pub fn claimOwnershipBody(handle: *const anyopaque, kind: Api.RoundKind) Error!?u64 {
    const self = borrow(handle);

    return self.active.round.claim(self.ctx, kind);
}

pub fn visitOwnershipBody(handle: *const anyopaque, kind: Api.RoundKind, body: u64) Error!void {
    const self = borrow(handle);

    return self.active.round.visit(self.ctx, kind, @intCast(body));
}

pub fn finishOwnershipRound(handle: *const anyopaque, publish: bool) void {
    const self = borrow(handle);

    if (publish) self.result = self.active.round.plans.result();

    self.close();
}

pub fn ownershipRoundOutcome(handle: *const anyopaque) Api.RoundOutcome {
    return borrow(handle).active.round.outcome;
}

pub fn beginOwnershipReplay(handle: *const anyopaque) bool {
    const self = borrow(handle);

    if (self.ctx.replay.trace == null) return false;

    self.active = .{ .replay = .init(self.ctx.workspace) };

    return true;
}

pub fn scanOwnershipReplay(handle: *const anyopaque, phase: Api.ReplayPhase, recovered: ?u32) Error!Api.ReplayPhase {
    const self = borrow(handle);

    return self.active.replay.advance(self.ctx, phase, recovered);
}

pub fn recoverOwnershipVisit(handle: *const anyopaque, phase: Api.ReplayPhase) Error!u32 {
    const self = borrow(handle);

    return self.active.replay.recover(self.ctx, phase);
}

pub fn publishOwnershipReplay(handle: *const anyopaque) Error!void {
    const self = borrow(handle);

    self.result = try self.active.replay.publish(self.ctx);
}

pub fn finishOwnershipReplay(handle: *const anyopaque) void {
    borrow(handle).close();
}
