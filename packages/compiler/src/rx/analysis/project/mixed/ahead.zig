//! Analyzes the ZX bodies and lowers the RX modules of one run of the dependency order on all cores before the run is
//! linked. Modules of one depth depend on none of each other, so each reads the shared tables as the run found them,
//! and linking still follows the order: the type merge maps a type a module made to the same type an earlier module of
//! the run added. A module this skips, whose analysis fails, or whose tables changed in ways the link cannot account
//! for is analyzed at its turn.
const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const State = @import("state.zig");
const Reuse = @import("reuse.zig");
const Zx = @import("zx.zig");
const Rx = @import("rx.zig");
const Module = @import("../../module.zig");
const Frame = @import("../history.zig").Frame;
const Inputs = @import("../call_inputs.zig");
const Body = @import("body.zig");
const Schedule = @import("schedule.zig");
const Candidates = @import("ahead/candidates.zig");
const Self = @This();

arenas: []std.heap.ArenaAllocator = &.{},
/// Holds the prepared bindings of the current run.
bindings: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
items: std.MultiArrayList(Item) = .empty,
next_item: usize = 0,
const Item = struct {
    position: u64,
    result: Result,
};

const Result = union(enum) {
    zx: struct { prepared: Zx.Prepared, outcome: ?Zx.Outcome = null },
    rx: struct { prepared: Rx.Prepared, value: ?Module.Value = null },
};

/// Fewer modules than this are analyzed at their turn: waking the other cores costs more than a run of two or three
/// modules saves.
const minimum = 4;
pub const Lowered = struct { prepared: Rx.Prepared, contract: Module.Contract };

fn initArenas(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (self.arenas.len != 0) return;

    self.arenas = try allocator.alloc(std.heap.ArenaAllocator, zx.parallel.width());

    for (self.arenas) |*arena| arena.* = .init(std.heap.smp_allocator);
}

pub fn deinit(self: *Self) void {
    for (self.arenas) |*arena| arena.deinit();

    self.bindings.deinit();
}

/// Analyzes a bounded prefix of the run and returns its module count. Runs below the parallel minimum are left to
/// their turn; only successfully prepared modules consume the batch's parallel slots.
pub fn analyze(self: *Self, state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, derived: Frame, reuse: *const Reuse, window: Schedule.Window, arguments: *const Inputs) std.mem.Allocator.Error!usize {
    const used = @min(self.arenas.len, self.items.len);
    const first = window.first;
    const end = window.end;

    for (self.arenas[0..used]) |*arena| _ = arena.reset(.retain_capacity);

    _ = self.bindings.reset(.retain_capacity);

    self.items.clearRetainingCapacity();

    self.next_item = 0;

    if (end - first < minimum) return end - first;

    var candidates = Candidates{ .state = state, .reuse = reuse, .local_calls = derived.loaded.local_calls, .position = first, .end = end };
    var initial: [minimum]Candidates.Item = undefined;

    for (&initial) |*candidate| candidate.* = candidates.next() orelse return end - first;
    try self.initArenas(state.allocator);

    const owner = state.owner;
    defer state.owner = owner;
    const limit = @max(self.arenas.len, minimum);
    var unprepared: []const Candidates.Item = &initial;

    while (self.items.len < limit) {
        const candidate = if (unprepared.len != 0) ready: {
            const value = unprepared[0];
            unprepared = unprepared[1..];

            break :ready value;
        } else candidates.next() orelse break;

        const index = state.graph.order[candidate.position];
        const issue = state.issue;
        state.owner = index;

        const result = prepare(self, state, cache, sources, derived, index, arguments, candidate.action) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                state.issue = issue;

                continue;
            },
        };

        try self.items.append(state.allocator, .{ .position = candidate.position, .result = result });
    }

    const batch = Schedule.preparedBatch(window, self.items.items(.position), self.arenas.len, limit, minimum);

    if (batch.participants == 0) {
        self.items.clearRetainingCapacity();

        return batch.consumed;
    }

    const Work = struct {
        state: *const State,
        results: []Result,
        arenas: []std.heap.ArenaAllocator,
        next: std.atomic.Value(usize) = .init(0),
        fn run(work: *@This(), participant: usize) void {
            const arena = work.arenas[participant].allocator();

            while (true) {
                const position = work.next.fetchAdd(1, .monotonic);

                if (position >= work.results.len) return;

                switch (work.results[position]) {
                    .zx => |*item| item.outcome = Zx.analyze(work.state, arena, item.prepared, &.{}) catch null,
                    .rx => |*item| item.value = Rx.lower(work.state, arena, item.prepared) catch null,
                }
            }
        }
    };

    var work = Work{ .state = state, .results = self.items.items(.result), .arenas = self.arenas };

    zx.parallel.spread(Work, &work, Work.run, batch.participants);

    return batch.consumed;
}

fn prepare(self: *Self, state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, derived: Frame, index: usize, arguments: *const Inputs, action: Body.Action) State.Error!Result {
    const allocator = self.bindings.allocator();

    switch (action) {
        .AnalyzeZX => return .{ .zx = .{ .prepared = try Zx.prepare(state, allocator, cache, sources, index, false) } },
        .LowerRX => {
            const source = state.graph.sources.at(index).rx;
            const module = derived.loaded.modules[source];
            const callees = @import("callees.zig");
            const ids = try callees.load(state, allocator, cache, sources, module);

            return .{ .rx = .{ .prepared = try Rx.prepare(state, allocator, index, module, derived.resolved.at(source), ids, arguments.module(source), state.functions.view()) } };
        },
        .Skip, .MissingSignature => unreachable,
    }
}

/// The analysis `analyze` made of the ZX body `index`, while the tables still allow linking it.
pub fn take(self: *const Self, state: *const State, selected: ?usize) ?Zx.Analyzed {
    const row = selected orelse return null;
    const item = &self.items.items(.result)[row];

    const outcome = switch (item.*) {
        .zx => |value| value.outcome orelse return null,
        .rx => return null,
    };

    return if (outcome == .analyzed and Zx.current(state, outcome.analyzed)) outcome.analyzed else null;
}

/// The lowering `analyze` made of the RX module `index`, while the tables still allow linking it.
pub fn lowered(self: *const Self, state: *const State, selected: ?usize) ?Lowered {
    const row = selected orelse return null;
    const item = &self.items.items(.result)[row];

    const lowering = switch (item.*) {
        .rx => |value| value,
        .zx => return null,
    };

    const value = lowering.value orelse return null;

    return if (value == .contract and Rx.current(state, lowering.prepared, value.contract)) .{ .prepared = lowering.prepared, .contract = value.contract } else null;
}

pub fn next(self: *Self, state: *const State, first: usize, end: usize, keep_skipped: bool) @import("schedule/dispatch.zig").Result {
    return @import("schedule/dispatch.zig").next(state, first, end, keep_skipped, self.items.items(.position), &self.next_item);
}
