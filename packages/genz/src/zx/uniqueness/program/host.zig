const std = @import("std");
const ir = @import("zx").ir;
const analysis = @import("../root.zig");
const Ahead = @import("../ahead.zig");
const Pool = @import("../pool.zig");
const Topology = @import("../topology.zig");
const Replay = @import("../trace.zig").Replay;
const generated = @import("genz_options").generated_analysis;
const Error = std.mem.Allocator.Error;
const Bodies = @import("bodies.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    slots: analysis.Slots,
    summaries: *analysis.Summaries,
    bodies: *const Bodies,
    calls: Topology.Calls,
    exported: []const ir.FunctionId,
    memo: *analysis.Memo,
    replay: *Replay,
    concurrent: bool,
    round_memory: ?std.heap.ArenaAllocator = null,
    pool: ?Pool = null,
    rounds: ?Rounds = null,
    const Rounds = struct {
        work: analysis.Work,
        reverse: Topology.Plan,
        ahead: Ahead,
    };
    pub fn run(self: *Context) Error!analysis.Result {
        errdefer self.release();

        if (generated) return @import("driver.zig").run(self);

        return @import("seed.zig").run(self);
    }

    pub fn roundMemory(self: *Context) std.mem.Allocator {
        if (self.round_memory == null) self.round_memory = .init(self.workspace);

        return self.round_memory.?.allocator();
    }
    pub fn open(self: *Context) Error!void {
        const memory = self.roundMemory();
        self.pool = try Pool.init(memory, self.concurrent);

        const ahead = try Ahead.init(memory, &self.pool.?, self.slots, self.summaries, self.bodies, self.calls.recursive);

        const prepared = if (generated)
            try analysis.Work.open(self.workspace, memory, self.calls.callees, self.exported)

        else seed: {
            const reverse = try Topology.buildSeed(memory, self.calls.callees, self.exported);
            const work = try analysis.Work.init(self.workspace, self.calls.active.len);

            break :seed .{ .work = work, .reverse = reverse };
        };

        self.rounds = .{
            .work = prepared.work,
            .reverse = prepared.reverse,
            .ahead = ahead,
        };

        if (generated) self.rounds.?.ahead.memo_rows.init(self.bodies);
    }

    pub fn release(self: *Context) void {
        if (self.rounds) |*rounds| rounds.work.deinit();
        if (self.pool) |*pool| pool.deinit();
        if (self.round_memory) |*memory| memory.deinit();

        self.rounds = null;
        self.pool = null;
        self.round_memory = null;
    }

    pub fn commit(self: *Context) Error!void {
        const trace = try self.replay.finish();

        if (self.memo.trace) |*previous| previous.deinit();

        self.memo.trace = trace;
    }
};
