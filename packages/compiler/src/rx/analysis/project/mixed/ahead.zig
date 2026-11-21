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
const Compilation = @import("../../module_compile.zig");
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

const PreparedZX = struct {
    prepared: Zx.Prepared,
    scratch: ?zx.Arena = null,
    outcome: ?Zx.Outcome = null,
    fn release(self: *PreparedZX) void {
        if (self.scratch) |*scratch| scratch.deinit();

        self.scratch = null;
        self.outcome = null;
    }
};

const Result = union(enum) {
    zx: PreparedZX,
    rx: struct { prepared: Rx.Prepared, value: ?Compilation.Value = null },
};

/// Fewer modules than this are analyzed at their turn: waking the other cores costs more than a run of two or three
/// modules saves.
const minimum = 4;
pub const Lowered = struct { prepared: Rx.Prepared, body: Compilation.Body };

fn initArenas(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (self.arenas.len != 0) return;

    self.arenas = try allocator.alloc(std.heap.ArenaAllocator, zx.parallel.width());

    for (self.arenas) |*arena| arena.* = .init(std.heap.smp_allocator);
}

pub fn deinit(self: *Self) void {
    self.clearResults();

    for (self.arenas) |*arena| arena.deinit();

    self.bindings.deinit();
}

fn clearResults(self: *Self) void {
    for (self.items.items(.result)) |*result| {
        if (result.* == .zx) result.zx.release();
    }

    self.items.clearRetainingCapacity();
}

/// Analyzes a bounded prefix of the run and returns its module count. Runs below the parallel minimum are left to
/// their turn; only successfully prepared modules consume the batch's parallel slots.
pub fn analyze(self: *Self, state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, derived: Frame, reuse: *const Reuse, window: Schedule.Window, arguments: *const Inputs) std.mem.Allocator.Error!usize {
    const used = @min(self.arenas.len, self.items.len);

    self.clearResults();

    for (self.arenas[0..used]) |*arena| _ = arena.reset(.retain_capacity);

    _ = self.bindings.reset(.retain_capacity);
    self.next_item = 0;
    const owner = state.owner;
    defer state.owner = owner;

    var frame: Preparation = .{ .ahead = self, .state = state, .cache = cache, .sources = sources, .derived = derived, .arguments = arguments };

    const batch = if (comptime Candidates.generated)
        try collect(&frame, reuse, window)
    else
        try self.collectSeed(&frame, reuse, window);

    if (batch.participants == 0) {
        self.clearResults();

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
                    .zx => |*item| {
                        item.scratch = .init(arena);
                        item.outcome = Zx.analyze(work.state, arena, &item.scratch.?, item.prepared, &.{}) catch null;
                    },
                    .rx => |*item| item.value = Rx.lower(work.state, arena, item.prepared) catch null,
                }
            }
        }
    };

    var work = Work{ .state = state, .results = self.items.items(.result), .arenas = self.arenas };

    zx.parallel.spread(Work, &work, Work.run, batch.participants);

    return batch.consumed;
}

const Preparation = struct {
    ahead: *Self,
    state: *State,
    cache: *frontend.project.ParseCache,
    sources: []const frontend.project.Source,
    derived: Frame,
    arguments: *const Inputs,
    fn borrow(handle: *const anyopaque) *Preparation {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn append(self: *Preparation, position: usize, index: usize, action: Body.Action) std.mem.Allocator.Error!bool {
        const state = self.state;
        const issue = state.issue;
        state.owner = index;

        const result = prepare(self.ahead, state, self.cache, self.sources, self.derived, index, self.arguments, action) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                state.issue = issue;

                return false;
            },
        };

        try self.ahead.items.append(state.allocator, .{ .position = position, .result = result });

        return true;
    }
};

pub fn reserveMixedWorkers(handle: *const anyopaque) std.mem.Allocator.Error!u64 {
    const frame = Preparation.borrow(handle);

    try frame.ahead.initArenas(frame.state.allocator);

    return frame.ahead.arenas.len;
}

pub fn prepareMixedPosition(handle: *const anyopaque, position: u64, index: u64, is_zx: bool) std.mem.Allocator.Error!bool {
    return Preparation.borrow(handle).append(@intCast(position), @intCast(index), if (is_zx) .AnalyzeZX else .LowerRX);
}

pub fn preparedMixedPositions(handle: *const anyopaque) []const u64 {
    return Preparation.borrow(handle).ahead.items.items(.position);
}

fn collect(frame: *Preparation, reuse: *const Reuse, window: Schedule.Window) std.mem.Allocator.Error!Schedule.Batch {
    const collect_plan = @import("generated_rx_mixed_collect");
    const Input = std.meta.Child(collect_plan.Input);
    const Selection = std.meta.Child(@FieldType(Input, "selection"));
    const state = frame.state;
    const graph = &state.graph;
    var slots: [Candidates.chunk_size]u64 = undefined;
    const positions: []u64 = &slots;
    const previous = if (reuse.aligned) reuse.prefix else null;

    const input: Input = .{
        .selection = &.{
            .order = @ptrCast(graph.order),
            .start = window.first,
            .end = window.end,
            .entry = graph.entry,
            .signatures = state.signature_indices,
            .local_calls = frame.derived.loaded.local_calls,
            .compiled_dependencies = graph.modules.items(.compiled_dependency),
            .history = if (previous) |snapshot| zx.columns.pointer(@typeInfo(@FieldType(Selection, "history")).optional.child, &snapshot.history) else null,
            .positions = @ptrCast(&positions),
        },
        .workspace = @ptrCast(frame),
        .minimum = minimum,
        .capacity = slots.len,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const batch = zx.columns.invoke(collect_plan.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .consumed = @intCast(batch.consumed), .participants = @intCast(batch.participants) };
}

fn collectSeed(self: *Self, frame: *Preparation, reuse: *const Reuse, window: Schedule.Window) std.mem.Allocator.Error!Schedule.Batch {
    const state = frame.state;
    const first = window.first;
    const end = window.end;
    const derived = frame.derived;

    if (end - first < minimum) return .{ .consumed = end - first, .participants = 0 };

    var candidates = Candidates{ .state = state, .reuse = reuse, .local_calls = derived.loaded.local_calls, .position = first, .end = end };
    var initial: [minimum]Candidates.Item = undefined;

    for (&initial) |*candidate| candidate.* = candidates.next() orelse return .{ .consumed = end - first, .participants = 0 };
    try self.initArenas(state.allocator);

    const limit = @max(self.arenas.len, minimum);
    var unprepared: []const Candidates.Item = &initial;

    while (self.items.len < limit) {
        const candidate = if (unprepared.len != 0) ready: {
            const value = unprepared[0];
            unprepared = unprepared[1..];

            break :ready value;
        } else candidates.next() orelse break;

        const index = state.graph.order[candidate.position];

        _ = try frame.append(candidate.position, index, candidate.action);
    }

    return Schedule.preparedBatch(window, self.items.items(.position), self.arenas.len, limit, minimum);
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

            return .{ .rx = .{ .prepared = try Rx.prepare(state, index, module, derived.resolved.at(source), ids, arguments.module(source), state.functions.view()) } };
        },
        .Skip, .MissingSignature => unreachable,
    }
}

/// Links a prepared body while its analysis storage is still alive.
pub fn link(self: *Self, state: *State, selected: ?usize) State.Error!?frontend.project.artifact.source_link.Loaded {
    const row = selected orelse return null;
    const item = &self.items.items(.result)[row];

    if (item.* != .zx) return null;

    defer item.zx.release();

    const outcome = item.zx.outcome orelse return null;

    if (outcome != .analyzed or !Zx.current(state, outcome.analyzed)) return null;

    _ = state.scratch.reset(.retain_capacity);

    return try Zx.link(state, outcome.analyzed);
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

    return if (value == .body and Rx.current(state, lowering.prepared, value.body)) .{ .prepared = lowering.prepared, .body = value.body } else null;
}

pub fn next(self: *Self, state: *const State, first: usize, end: usize, keep_skipped: bool) ?@import("schedule/dispatch.zig").Result {
    return @import("schedule/dispatch.zig").next(state, first, end, keep_skipped, self.items.items(.position), &self.next_item);
}
