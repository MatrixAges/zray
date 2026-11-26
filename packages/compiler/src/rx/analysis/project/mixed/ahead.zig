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
const generated = @import("rx_options").generated_graph;
const Self = @This();
const Diagnostic = @import("../../call/target.zig").Diagnostic;
const CandidateHandle = if (Candidates.generated) @import("rx_execution_abi").layouts.@"zig:rx_project_host".MixedCandidate else anyopaque;

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
    if (self.items.len == 0) return;

    if (comptime generated) {
        const rule = @import("generated_rx_retire_mixed_results");
        const input: std.meta.Child(rule.Input) = .{ .workspace = @ptrCast(self), .rows = self.items.len };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeIn(empty.allocator(), &input) catch unreachable;

        return;
    }

    self.clearSeed();
}

fn clearSeed(self: *Self) void {
    for (self.items.items(.result)) |*result| {
        if (result.* == .zx) result.zx.release();
    }

    self.items.clearRetainingCapacity();
}

fn borrowWorkspace(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}

pub fn mixedResultIsZX(handle: *anyopaque, row: u64) bool {
    return borrowWorkspace(handle).items.items(.result)[@intCast(row)] == .zx;
}

pub fn releaseMixedZXResult(handle: *anyopaque, row: u64) void {
    borrowWorkspace(handle).items.items(.result)[@intCast(row)].zx.release();
}

pub fn clearMixedResults(handle: *anyopaque) void {
    borrowWorkspace(handle).items.clearRetainingCapacity();
}

pub fn resetMixedWorker(handle: *anyopaque, index: u64) void {
    _ = borrowWorkspace(handle).arenas[@intCast(index)].reset(.retain_capacity);
}

fn resetBindings(self: *Self) void {
    _ = self.bindings.reset(.retain_capacity);
    self.next_item = 0;
}

pub fn resetMixedBindings(handle: *anyopaque) void {
    borrowWorkspace(handle).resetBindings();
}

/// Analyzes a bounded prefix of the run and returns its module count. Runs below the parallel minimum are left to
/// their turn; only successfully prepared modules consume the batch's parallel slots.
pub fn analyze(self: *Self, state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, derived: Frame, reuse: *const Reuse, window: Schedule.Window, arguments: *const Inputs) std.mem.Allocator.Error!usize {
    const owner = state.owner;
    defer state.owner = owner;

    var frame: Preparation = .{ .ahead = self, .state = state, .cache = cache, .sources = sources, .derived = derived, .arguments = arguments };

    if (comptime Candidates.generated) return executeWindow(&frame, reuse, window);

    const used = @min(self.arenas.len, self.items.len);

    self.clearSeed();

    for (self.arenas[0..used]) |*arena| _ = arena.reset(.retain_capacity);

    self.resetBindings();

    const batch = try self.collectSeed(&frame, reuse, window);

    if (batch.participants == 0) {
        self.clearSeed();
    } else {
        self.execute(state, batch.participants);
    }

    return batch.consumed;
}

fn execute(self: *Self, state: *const State, participants: usize) void {
    var work = Work{ .state = state, .results = self.items.items(.result), .arenas = self.arenas };

    zx.parallel.spread(Work, &work, Work.run, participants);
}

const Work = struct {
    state: *const State,
    results: []Result,
    arenas: []std.heap.ArenaAllocator,
    next: std.atomic.Value(usize) = .init(0),
    fn run(work: *Work, participant: usize) void {
        const worker: Worker = .{ .state = work.state, .results = work.results, .arena = work.arenas[participant].allocator() };

        while (true) {
            const position = work.next.fetchAdd(1, .monotonic);

            if (position >= work.results.len) return;

            switch (work.results[position]) {
                .zx => worker.analyze(position),
                .rx => worker.lower(position),
            }
        }
    }
};

const Worker = struct {
    state: *const State,
    results: []Result,
    arena: std.mem.Allocator,
    fn analyze(self: *const Worker, position: usize) void {
        const item = &self.results[position].zx;

        item.scratch = .init(self.arena);
        item.outcome = Zx.analyze(self.state, self.arena, &item.scratch.?, item.prepared, &.{}) catch null;
    }
    fn lower(self: *const Worker, position: usize) void {
        const item = &self.results[position].rx;
        item.value = Rx.lower(self.state, self.arena, item.prepared) catch null;
    }
};

const Preparation = struct {
    ahead: *Self,
    state: *State,
    cache: *frontend.project.ParseCache,
    sources: []const frontend.project.Source,
    derived: Frame,
    arguments: *const Inputs,
    issue: ?Diagnostic = null,
    candidate: Result = undefined,
    fn borrow(handle: *anyopaque) *Preparation {
        return @ptrCast(@alignCast(handle));
    }
    fn open(self: *Preparation, index: usize) void {
        self.issue = self.state.issue;
        self.state.owner = index;
    }

    fn restore(self: *Preparation) void {
        self.state.issue = self.issue;
    }

    fn prepareZX(self: *Preparation, index: usize) State.Error!Zx.Prepared {
        return Zx.prepare(self.state, self.ahead.bindings.allocator(), self.cache, self.sources, index, false);
    }
    fn prepareRX(self: *Preparation, index: usize) State.Error!Rx.Prepared {
        const source = self.state.graph.sources.at(index).rx;
        const module = self.derived.loaded.modules[source];
        const callees = @import("callees.zig");
        const ids = try callees.load(self.state, self.ahead.bindings.allocator(), self.cache, self.sources, module);

        return Rx.prepare(self.state, index, module, self.derived.resolved.at(source), ids, self.arguments.module(source), self.state.functions.view());
    }
    fn append(self: *Preparation, position: u64, result: *const Result) std.mem.Allocator.Error!void {
        try self.ahead.items.append(self.state.allocator, .{ .position = position, .result = result.* });
    }
    fn appendSeed(self: *Preparation, position: usize, index: usize, action: Body.Action) std.mem.Allocator.Error!void {
        self.open(index);

        const result: State.Error!Result = switch (action) {
            .AnalyzeZX => if (self.prepareZX(index)) |prepared| .{ .zx = .{ .prepared = prepared } } else |err| err,
            .LowerRX => if (self.prepareRX(index)) |prepared| .{ .rx = .{ .prepared = prepared } } else |err| err,
            .Skip, .MissingSignature => unreachable,
        };

        const ready = result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSourceGraph => return self.restore(),
        };

        try self.append(position, &ready);
    }
};

pub fn reserveMixedWorkers(handle: *anyopaque) std.mem.Allocator.Error!u64 {
    const frame = Preparation.borrow(handle);

    try frame.ahead.initArenas(frame.state.allocator);

    return frame.ahead.arenas.len;
}

pub fn openMixedCandidate(handle: *anyopaque, index: u64) void {
    Preparation.borrow(handle).open(@intCast(index));
}

pub fn prepareMixedZXCandidate(handle: *anyopaque, index: u64) std.mem.Allocator.Error!?*const CandidateHandle {
    const frame = Preparation.borrow(handle);

    const prepared = frame.prepareZX(@intCast(index)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSourceGraph => return null,
    };

    frame.candidate = .{ .zx = .{ .prepared = prepared } };

    return @ptrCast(&frame.candidate);
}

pub fn prepareMixedRXCandidate(handle: *anyopaque, index: u64) std.mem.Allocator.Error!?*const CandidateHandle {
    const frame = Preparation.borrow(handle);

    const prepared = frame.prepareRX(@intCast(index)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSourceGraph => return null,
    };

    frame.candidate = .{ .rx = .{ .prepared = prepared } };

    return @ptrCast(&frame.candidate);
}

pub fn recordMixedCandidate(handle: *anyopaque, position: u64, candidate: *const anyopaque) std.mem.Allocator.Error!void {
    try Preparation.borrow(handle).append(position, @ptrCast(@alignCast(candidate)));
}

pub fn restoreMixedCandidateDiagnostic(handle: *anyopaque) void {
    Preparation.borrow(handle).restore();
}

pub fn preparedMixedPositions(handle: *anyopaque) []const u64 {
    return Preparation.borrow(handle).ahead.items.items(.position);
}

pub fn executeMixedWorkers(handle: *anyopaque, participants: u64) void {
    const frame = Preparation.borrow(handle);

    frame.ahead.execute(frame.state, @intCast(participants));
}

fn executeWindow(frame: *Preparation, reuse: *const Reuse, window: Schedule.Window) std.mem.Allocator.Error!usize {
    const collect_plan = @import("generated_rx_mixed_collect");
    const Input = std.meta.Child(collect_plan.Input);
    const Selection = std.meta.Child(@FieldType(Input, "selection"));
    const state = frame.state;
    const graph = &state.graph;
    const order = @import("../history/columns.zig").words(std.mem.sliceAsBytes(graph.order));
    var slots: [Candidates.chunk_size]u64 = undefined;
    var positions: []u64 = &slots;
    const previous = if (reuse.aligned) reuse.prefix else null;

    const input: Input = .{
        .selection = &.{
            .order = @ptrCast(&order),
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
        .prior = &.{ .workspace = @ptrCast(frame.ahead), .rows = frame.ahead.items.len, .workers = frame.ahead.arenas.len },
        .minimum = minimum,
        .capacity = slots.len,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const consumed = zx.columns.invoke(collect_plan.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return @intCast(consumed);
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

        try frame.appendSeed(candidate.position, index, candidate.action);
    }

    return Schedule.preparedBatch(window, self.items.items(.position), self.arenas.len, limit, minimum);
}

pub fn zxRow(self: *const Self, selected: ?usize) ?usize {
    const row = selected orelse return null;

    return if (self.items.items(.result)[row] == .zx) row else null;
}

pub fn acceptsZX(self: *const Self, state: *const State, row: usize) bool {
    const item = &self.items.items(.result)[row].zx;
    const outcome = if (item.outcome) |*value| value else return false;

    return outcome.* == .analyzed and Zx.current(state, outcome.analyzed);
}

pub fn retireZX(self: *Self, row: usize) void {
    self.items.items(.result)[row].zx.release();
}

/// Links an accepted body while its dedicated analysis storage is still alive.
pub fn linkZX(self: *Self, state: *State, row: usize, index: usize) State.Error!void {
    const item = &self.items.items(.result)[row].zx;

    defer item.release();

    _ = state.scratch.reset(.retain_capacity);

    try Zx.link(state, item.outcome.?.analyzed, state.finished.destination(index));
}

pub fn acceptedRX(self: *const Self, state: *const State, selected: ?usize) ?usize {
    const row = selected orelse return null;
    const item = &self.items.items(.result)[row];

    if (item.* != .rx) return null;

    const lowering = &item.rx;
    const value = if (lowering.value) |*value| value else return null;

    return if (value.* == .body and Rx.current(state, lowering.prepared, value.body)) row else null;
}

pub fn linkRX(self: *Self, state: *State, row: usize) State.Error!?*Compilation.Metadata {
    const item = &self.items.items(.result)[row].rx;

    _ = state.scratch.reset(.retain_capacity);

    return Rx.link(state, item.prepared, item.value.?.body);
}

pub fn next(self: *Self, state: *const State, first: usize, end: usize, keep_skipped: bool) ?@import("schedule/dispatch.zig").Result {
    return @import("schedule/dispatch.zig").next(state, first, end, keep_skipped, self.items.items(.position), &self.next_item);
}
