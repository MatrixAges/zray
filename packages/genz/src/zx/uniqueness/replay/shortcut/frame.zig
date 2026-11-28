const std = @import("std");
const Analysis = @import("../../root.zig");
const Context = @import("../../program/host.zig").Context;
const compute = @import("../../program/visit/compute.zig");
const Memo = @import("../../memo.zig");
const Growth = @import("../../growth.zig");
const Cursor = @import("../shortcut.zig");
const Replacements = @import("replacements.zig");
const scan = @import("scan.zig");
const Error = std.mem.Allocator.Error;
const Phase = @import("../../program/driver.zig").ReplayPhase;
const Self = @This();

scratch: std.heap.ArenaAllocator,
staged: std.heap.ArenaAllocator,
replacements: Replacements = .{},
body: usize = 0,
visit: usize = 0,
growth: Growth.Rows = undefined,
pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .scratch = .init(allocator), .staged = .init(allocator) };
}

pub fn close(self: *Self) void {
    self.staged.deinit();
    self.scratch.deinit();
}

pub fn advance(self: *Self, ctx: *Context, phase: Phase, recovered: ?u32) Error!Phase {
    if (!self.scratch.reset(.retain_capacity)) return error.OutOfMemory;

    const next = try scan.advance(ctx, &ctx.memo.trace.?, self.scratch.allocator(), self.staged.allocator(), &self.replacements, .{
        .body = self.body,
        .visit = self.visit,
        .phase = @fromBackingInt(@backingInt(phase)),
    }, recovered);

    self.body = next.cursor.body;
    self.visit = next.cursor.visit;
    self.growth = next.growth;

    return @fromBackingInt(@backingInt(next.cursor.phase));
}

pub fn recover(self: *Self, ctx: *Context, phase: Phase) Error!u32 {
    return switch (phase) {
        .Settled => prepare(.settled, ctx, self.body, &self.growth, self.scratch.allocator()),
        .Demanded => prepare(.demanded, ctx, self.body, &self.growth, self.scratch.allocator()),
        .Planned => prepare(.planned, ctx, self.body, &self.growth, self.scratch.allocator()),
        else => unreachable,
    };
}

pub fn publish(self: *Self, ctx: *Context) Error!Analysis.Result {
    return Cursor.publish(ctx.allocator, &ctx.memo.trace.?, ctx.replay, self.replacements.rows(), ctx.calls.active);
}

fn prepare(comptime kind: Memo.Kind, ctx: *Context, body: usize, growth: *Growth.Store, scratch: std.mem.Allocator) Error!u32 {
    const result = try compute.run(kind, false, .{
        .bodies = ctx.bodies,
        .slots = ctx.slots,
        .summaries = ctx.summaries,
        .body = body,
        .growth = growth,
        .scratch = scratch,
        .lasting = ctx.roundMemory(),
        .owner = ctx.memo.arena.allocator(),
        .restored_growth = kind == .demanded,
        .memo = ctx.memo,
    });

    return result.row.?;
}
