const std = @import("std");
const ir = @import("zx").ir;
const analysis = @import("../root.zig");
const Ahead = @import("../ahead.zig");
const Pool = @import("../pool.zig");
const Topology = @import("../topology.zig");
const Replay = @import("../trace.zig").Replay;
const generated = @import("genz_options").generated_analysis;
const Error = std.mem.Allocator.Error;

pub const Context = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    program: *const ir.Program,
    slots: analysis.Slots,
    summaries: *analysis.Summaries,
    units: []const ?*analysis.Unit,
    callees: []const []const u32,
    exported: []const ir.FunctionId,
    memo: *analysis.Memo,
    replay: *Replay,
    concurrent: bool,
    pool: ?Pool = null,
    rounds: ?Rounds = null,
    const Rounds = struct {
        work: analysis.Work,
        reverse: Topology.Plan,
        ahead: Ahead,
    };
    pub fn run(self: *Context) Error!analysis.Result {
        defer {
            if (self.rounds) |*rounds| rounds.work.deinit();
            if (self.pool) |*pool| pool.deinit();
        }

        if (comptime !generated) return self.runSeed();

        const driver = @import("generated_uniqueness_program");
        const Input = std.meta.Child(driver.Input);
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        var result: analysis.Result = .{ .functions = &.{}, .entry = .{ .flags = &.{} } };

        const input: Input = .{
            .context = @ptrCast(self),
            .target = @ptrCast(&result),
            .following = self.replay.trace != null,
            .persistent = self.memo.persistent,
        };

        driver.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        return result;
    }
    fn reuse(self: *Context) Error!?analysis.Result {
        return analysis.shortcut(self.allocator, self.workspace, self.temporary, self.program.*, self.slots, self.summaries, self.units, self.memo, self.replay);
    }
    fn open(self: *Context) Error!void {
        self.pool = try Pool.init(self.temporary, self.concurrent);
        const ahead = try Ahead.init(self.temporary, &self.pool.?, self.program.functions, self.slots, self.summaries, self.units);
        const reverse = try Topology.build(self.temporary, self.callees, self.exported);

        self.rounds = .{
            .work = try analysis.Work.init(self.workspace, self.units.len),
            .reverse = reverse,
            .ahead = ahead,
        };
    }
    fn prepare(self: *Context, reset: bool, clear: bool) Error!u64 {
        const rounds = &self.rounds.?;

        return rounds.work.prepare(self.program, self.summaries, rounds.reverse.known, reset, clear);
    }
    fn settle(self: *Context, budget: u64) Error!bool {
        const rounds = &self.rounds.?;

        return analysis.settle(self.workspace, &rounds.work, self.program.*, self.slots, self.summaries, self.units, rounds.reverse.callers, self.memo, self.replay, &rounds.ahead, budget);
    }
    fn demand(self: *Context) Error!bool {
        const rounds = &self.rounds.?;

        return analysis.demand(self.workspace, &rounds.work, self.program.*, self.slots, self.summaries, self.units, rounds.reverse.callers, self.memo, self.replay, &rounds.ahead);
    }

    fn plans(self: *Context) Error!analysis.Result {
        const rounds = &self.rounds.?;

        return analysis.publishPlans(self.allocator, self.workspace, self.temporary, self.program.*, self.slots, self.summaries, self.units, &rounds.work, self.memo, self.replay, &rounds.ahead);
    }
    fn commit(self: *Context) Error!void {
        const trace = try self.replay.finish();

        if (self.memo.trace) |*previous| previous.deinit();

        self.memo.trace = trace;
    }

    fn runSeed(self: *Context) Error!analysis.Result {
        if (self.replay.trace != null) {
            if (try self.reuse()) |result| return result;
        }

        try self.open();

        while (true) {
            const budget = try self.prepare(true, false);
            const exhausted = try self.settle(budget);
            _ = try self.prepare(false, exhausted);

            if (!try self.demand()) break;
        }

        _ = try self.prepare(false, false);

        const result = try self.plans();

        if (self.memo.persistent) try self.commit();

        return result;
    }
};

const Native = struct {
    fn context(handle: *anyopaque) *Context {
        return @ptrCast(@alignCast(handle));
    }

    fn result(target: *anyopaque) *analysis.Result {
        return @ptrCast(@alignCast(target));
    }

    fn replay(handle: *anyopaque, target: *anyopaque, reused: *bool) callconv(.c) bool {
        const plan = context(handle).reuse() catch return false;

        if (plan) |value| result(target).* = value;

        reused.* = plan != null;

        return true;
    }

    fn open(handle: *anyopaque) callconv(.c) bool {
        context(handle).open() catch return false;

        return true;
    }

    fn prepare(handle: *anyopaque, reset: bool, clear: bool, budget: *u64) callconv(.c) bool {
        budget.* = context(handle).prepare(reset, clear) catch return false;

        return true;
    }

    fn settle(handle: *anyopaque, budget: u64, exhausted: *bool) callconv(.c) bool {
        exhausted.* = context(handle).settle(budget) catch return false;

        return true;
    }

    fn demand(handle: *anyopaque, changed: *bool) callconv(.c) bool {
        changed.* = context(handle).demand() catch return false;

        return true;
    }

    fn plans(handle: *anyopaque, target: *anyopaque) callconv(.c) bool {
        result(target).* = context(handle).plans() catch return false;

        return true;
    }

    fn commit(handle: *anyopaque) callconv(.c) bool {
        context(handle).commit() catch return false;

        return true;
    }
};

comptime {
    if (generated) {
        @export(&Native.replay, .{ .name = "zxcUniquenessReplay" });
        @export(&Native.open, .{ .name = "zxcUniquenessOpen" });
        @export(&Native.prepare, .{ .name = "zxcUniquenessPrepare" });
        @export(&Native.settle, .{ .name = "zxcUniquenessSettle" });
        @export(&Native.demand, .{ .name = "zxcUniquenessDemand" });
        @export(&Native.plans, .{ .name = "zxcUniquenessPlans" });
        @export(&Native.commit, .{ .name = "zxcUniquenessCommit" });
    }
}
