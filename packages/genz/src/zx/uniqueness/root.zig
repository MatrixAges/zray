const std = @import("std");
const ir = @import("zx").ir;
const Function = @import("function.zig");
const Level = @import("level.zig").Level;
const Growth = @import("growth.zig");
const Order = @import("order/seed.zig");
const Identity = @import("identity.zig");
const Trace = @import("trace.zig");
const Shortcut = @import("replay/shortcut.zig");
pub const Memo = @import("memo.zig");
const Sites = @import("sites/seed.zig");
const Ahead = @import("ahead.zig");
const Round = @import("work/round.zig");
const Topology = @import("topology.zig");
pub const Basis = @import("basis.zig");
pub const Slots = @import("slots.zig");
pub const Summaries = @import("summaries.zig");
pub const Flags = Function.Flags;
/// How every list update of the program lowers. Appends extend a headered buffer in place when the appended value
/// sits at the buffer's frontier, checked at run time, so they need no uniqueness; element writes and pops rely on
/// static uniqueness. Facts start optimistic and only ever weaken, so the greatest fixpoint is sound. Plain lists that
/// reach an append get one growth copy where they enter; each new copy restarts the fixpoint, and copies only accrue.
pub const Renewal = Function.Renewal;
pub const Renewals = Function.Renewals;
pub const Plan = Function.Plan;
pub const Result = struct { functions: []const Plan, entry: Plan };

pub const Unit = struct {
    unit: Function.Unit,
    body: ir.Block,
    /// Built on the body's first analysis; a build that replays every state of the body never needs them.
    passes: ?Function.Passes = null,
    growth: Growth.Store,
    callees: []const u32,
    identity: *const Trace.Digest = &@as(Trace.Digest, @splat(0)),
    pub fn state(self: *const Unit, index: usize) Memo.State {
        return .{ .identity = self.identity.*, .index = index, .input = self.unit.input, .callees = self.callees, .growth = &self.growth };
    }

    /// The passes over the body are built on first use in `lasting`, which outlives every later analysis.
    pub fn initialize(self: *Unit, allocator: std.mem.Allocator, lasting: std.mem.Allocator, functions: ir.FunctionTable, slots: Slots, summaries: *Summaries, growth: ?*Growth.Store, record_reads: bool) std.mem.Allocator.Error!Function {
        if (self.passes == null) {
            if (@import("genz_options").generated_analysis) {
                self.passes = try @import("function/prepared.zig").build(lasting, allocator, &self.unit, self.body, slots, summaries);
            } else {
                const order = try Order.create(lasting, self.unit.symbols, self.unit.expressions, self.body);

                self.passes = .{ .order = order, .sites = undefined, .operations = undefined, .rows = undefined };
                const passes = &self.passes.?;
                passes.sites = try Sites.create(lasting, &passes.order, slots, self.unit.symbols, self.unit.expressions, summaries);
                passes.operations = try Function.collectOperations(lasting, &passes.order, self.unit.expressions);
                passes.rows = try Function.readRows(lasting, self.unit.expressions);
            }
        }

        const passes = &self.passes.?;
        var unit = self.unit;

        if (growth) |copies| unit.growth = copies;

        return Function.initialize(allocator, functions, unit, passes, slots, summaries, record_reads);
    }
};

/// `exported` functions are also called from outside the program, so nothing is known about their input. A persistent
/// `memo` carries body analyses over from earlier programs; without one, repeated states only replay within this call.
pub fn analyze(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Basis, persistent: ?*Memo) std.mem.Allocator.Error!Result {
    return analyzeWithConcurrency(allocator, workspace, program, exported, basis, persistent, false);
}

/// All allocators must be threadsafe, including shared parents and the exclusively borrowed memo.
pub fn analyzeConcurrent(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Basis, persistent: ?*Memo) std.mem.Allocator.Error!Result {
    return analyzeWithConcurrency(allocator, workspace, program, exported, basis, persistent, true);
}

fn analyzeWithConcurrency(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Basis, persistent: ?*Memo, comptime concurrent: bool) std.mem.Allocator.Error!Result {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    var local = Memo.init(workspace, false);

    defer local.deinit();

    const memo = persistent orelse &local;
    const temporary = scratch.allocator();
    const slots = basis.slots;
    var summary_memory = std.heap.ArenaAllocator.init(workspace);

    defer summary_memory.deinit();

    var summaries = try Summaries.create(summary_memory.allocator(), program, basis, .program);
    const count = program.functions.count();
    const units = try temporary.alloc(?*Unit, count + 1);
    const topology = try Topology.collect(temporary, program);

    for (0..count) |index| {
        const function = program.functions.at(index);

        units[index] = if (function.external != null) null else try prepare(temporary, .{ .symbols = function.symbols, .expressions = function.expressions, .input_type = function.input_type, .output_type = function.output_type, .input = summaries.input[index], .function = index, .growth = undefined }, function.body.block(), topology.callees[index]);
    }

    units[count] = if (program.type_only) null else try prepare(temporary, .{ .symbols = program.symbols, .expressions = program.expressions, .input_type = program.input_type, .output_type = program.output_type, .input = &.{}, .function = null, .growth = undefined }, program.body.block(), topology.callees[count]);

    var replay = Trace.Replay{ .allocator = temporary };

    if (memo.persistent) {
        const shared = Identity.program(program, basis);
        const identities = try temporary.alloc(Trace.Digest, units.len);

        identify(shared, basis.contents, units, identities);

        if (memo.record_trace) {
            const previous = if (memo.trace) |*trace| trace else null;
            const key = Identity.combine(&shared, std.mem.sliceAsBytes(exported));
            replay = try .init(temporary, memo.arena.child_allocator, previous, key, identities, topology.callees);
        }
    }

    defer replay.deinit();

    var state: @import("program/host.zig").Context = .{
        .allocator = allocator,
        .workspace = workspace,
        .temporary = temporary,
        .program = &program,
        .slots = slots,
        .summaries = &summaries,
        .units = units,
        .calls = topology,
        .exported = exported,
        .memo = memo,
        .replay = &replay,
        .concurrent = concurrent,
    };

    return state.run();
}

/// The plan of an entry body analyzed on its own, as a host entry into functions planned for another program: no
/// callee summary is known, so only the body's own appends and growth copies count.
pub fn analyzeEntry(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, basis: *const Basis) std.mem.Allocator.Error!Plan {
    if (program.type_only) return .{ .flags = &.{} };

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    var summaries = try Summaries.create(scratch.allocator(), program, basis, .entry);

    return analyzeEntryWith(allocator, workspace, program, basis, &summaries);
}

/// Entries into the same functions reuse `.entry` summaries. Callee facts stay unknown and only the demands reset.
pub fn analyzeEntryWith(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, basis: *const Basis, summaries: *Summaries) std.mem.Allocator.Error!Plan {
    if (program.type_only) return .{ .flags = &.{} };

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const slots = basis.slots;
    const generated = @import("genz_options").generated_analysis;

    if (!generated) summaries.clearWants();

    const unit = try prepare(temporary, .{ .symbols = program.symbols, .expressions = program.expressions, .input_type = program.input_type, .output_type = program.output_type, .input = &.{}, .function = null, .growth = undefined }, program.body.block(), &.{});

    if (generated) {
        var function = try unit.initialize(temporary, temporary, program.functions, slots, summaries, null, false);

        return @import("function/entry.zig").analyze(&function, allocator);
    }

    while (true) {
        var analysis = try unit.initialize(temporary, temporary, program.functions, slots, summaries, null, false);

        _ = try analysis.demand(temporary);

        if (!analysis.grew) break;
    }

    var analysis = try unit.initialize(temporary, temporary, program.functions, slots, summaries, null, false);

    return analysis.plan(allocator);
}

pub const Work = if (@import("genz_options").generated_analysis) @import("work.zig") else @import("work/seed.zig");

/// Queues for analysis ahead the bodies at the front of the queue, unless the worklist follows a trace, whose visits
/// are recalled instead of analyzed.
fn lookAhead(comptime kind: Memo.Kind, work: *const Work, memo: *Memo, replay: *const Trace.Replay, ahead: *Ahead) std.mem.Allocator.Error!void {
    if (replay.trace != null) return;
    try ahead.request(kind, memo, work.pending());
}

pub fn publishPlans(allocator: std.mem.Allocator, workspace: std.mem.Allocator, temporary: std.mem.Allocator, program: ir.Program, slots: Slots, summaries: *Summaries, units: []const ?*Unit, work: *Work, memo: *Memo, replay: *Trace.Replay, ahead: *Ahead) std.mem.Allocator.Error!Result {
    ahead.begin(.planned);
    defer ahead.finish();

    var plan_round = std.heap.ArenaAllocator.init(workspace);

    defer plan_round.deinit();

    const count = program.functions.count();
    const plan_owner = if (memo.persistent) memo.arena.allocator() else allocator;
    const plans = try allocator.alloc(Plan, count);
    var entry_plan = Plan{ .flags = &.{} };

    @memset(plans, .{ .flags = &.{} });

    while (true) {
        try lookAhead(.planned, work, memo, replay, ahead);

        const index = try work.pop() orelse break;
        const unit = units[index].?;

        const recalled = if (memo.persistent)
            (try replay.recall(.planned, index)) orelse try memo.getPlanned(summaries, unit.state(index))

        else
            null;

        const early = try ahead.take(.planned, index);

        const built = if (recalled) |found| found.plan() else if (early) |found| try found.copy(plan_owner) else fresh: {
            _ = plan_round.reset(.retain_capacity);

            var analysis = try unit.initialize(plan_round.allocator(), temporary, program.functions, slots, summaries, null, false);

            break :fresh try analysis.plan(plan_owner);
        };

        const plan = if (memo.persistent) stored: {
            const record = recalled orelse try memo.putOwnedPlan(memo.key, built);

            try replay.met(.planned, index, record, memo);

            break :stored try built.copy(allocator);
        } else built;

        if (index < count) plans[index] = plan else entry_plan = plan;
    }

    return .{ .functions = plans, .entry = entry_plan };
}

/// The greatest fixpoint of the summaries for the current growth copies, or no facts if it does not settle in time. A
/// body is analyzed again only when a callee output it reads or its own input weakened.
pub fn settle(workspace: std.mem.Allocator, work: *Work, program: ir.Program, slots: Slots, summaries: *Summaries, units: []const ?*Unit, callers: []const []const u64, memo: *Memo, replay: *Trace.Replay, ahead: *Ahead, budget: u64) std.mem.Allocator.Error!bool {
    const count = program.functions.count();
    var round = std.heap.ArenaAllocator.init(workspace);

    defer round.deinit();

    var remaining = budget;

    ahead.begin(.settled);
    defer ahead.finish();

    while (true) {
        try lookAhead(.settled, work, memo, replay, ahead);

        const index = switch (try work.takeSettlement(&remaining)) {
            .done => return false,
            .exhausted => return true,
            .body => |index| index,
        };

        _ = round.reset(.retain_capacity);

        const unit = units[index].?;
        const recalled = (try replay.recall(.settled, index)) orelse try memo.getSettled(summaries, unit.state(index));
        const early = try ahead.take(.settled, index);
        const known = recalled orelse if (early) |found| try memo.putSettled(memo.key, found.passed, found.output) else null;
        var changed: []const u64 = undefined;

        const settled = if (known) |settled| replayed: {
            changed = try Function.replay(round.allocator(), summaries, settled.passed);

            break :replayed settled;
        } else analyzed: {
            var analysis = try unit.initialize(round.allocator(), ahead.kept(), program.functions, slots, summaries, null, false);
            const result = try analysis.settle(memo.arena.allocator(), if (index == count) 0 else summaries.output[index].len);
            changed = result.changed;

            break :analyzed try memo.putOwnedSettled(memo.key, result.passed, result.output);
        };

        try replay.met(.settled, index, settled, memo);

        try work.publish(.{
            .program = &program,
            .outputs = summaries.output,
            .dirty = ahead.dirty,
            .changed = changed,
            .callers = callers[index],
            .body = index,
            .levels = settled.output,
        });
    }
}

/// Spreads the growth-copy demand until no input, output or copy is newly demanded; reports whether copies were added.
pub fn demand(workspace: std.mem.Allocator, work: *Work, program: ir.Program, slots: Slots, summaries: *Summaries, units: []const ?*Unit, callers: []const []const u64, memo: *Memo, replay: *Trace.Replay, ahead: *Ahead) std.mem.Allocator.Error!bool {
    var round = std.heap.ArenaAllocator.init(workspace);

    defer round.deinit();

    var added = false;

    ahead.begin(.demanded);
    defer ahead.finish();

    while (true) {
        try lookAhead(.demanded, work, memo, replay, ahead);

        const index = try work.pop() orelse break;
        _ = round.reset(.retain_capacity);
        const unit = units[index].?;
        const state = unit.state(index);
        const recalled = (try replay.recall(.demanded, index)) orelse try memo.getDemanded(summaries, state);
        const early = try ahead.take(.demanded, index);
        var changed: []const u64 = undefined;

        const demanded = if (recalled) |demanded| replayed: {
            changed = try Function.replayMarks(round.allocator(), summaries, demanded.marks);

            try Growth.restore(&unit.growth, .{ .normalized = demanded.normalized, .renewed = demanded.renewed });

            break :replayed demanded;
        } else if (early) |found| ahead: {
            const rows = if (@import("genz_options").generated_analysis and found.grew)
                try found.growth.copy(memo.arena.allocator())
            else
                found.growth;

            try Growth.restore(&unit.growth, rows);

            changed = try Function.replayMarks(round.allocator(), summaries, found.marks);

            break :ahead try memo.putDemanded(memo.key, found.marks, &unit.growth, found.grew);
        } else analyzed: {
            var analysis = try unit.initialize(round.allocator(), ahead.kept(), program.functions, slots, summaries, null, false);
            const result = try analysis.demand(memo.arena.allocator());
            changed = result.changed;

            break :analyzed try memo.putOwnedDemanded(memo.key, result.marks, &unit.growth, analysis.grew);
        };

        try replay.met(.demanded, index, demanded, memo);
        if (demanded.grew) added = true;
        try work.notify(ahead.dirty, program, changed, callers[index], index);
    }

    return added;
}

/// The plans of an analysis that takes the path of the trace it follows, known without walking it: every changed body,
/// analyzed again in each state the trace met it in, settles and demands as recorded, so every other body meets what
/// it met before. Only the plans of the changed bodies are new. Null, with the summaries and growth copies as they
/// were, when a changed body differs.
pub fn shortcut(allocator: std.mem.Allocator, workspace: std.mem.Allocator, temporary: std.mem.Allocator, program: ir.Program, slots: Slots, summaries: *Summaries, units: []const ?*Unit, memo: *Memo, replay: *const Trace.Replay) std.mem.Allocator.Error!?Result {
    const trace = &memo.trace.?;
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const Replacement = struct { visit: usize, value: Memo.Planned };
    var replacements: std.ArrayList(Replacement) = .empty;
    var cursor: Shortcut = .{};

    while (true) {
        cursor = cursor.next(&program, trace, replay.changed);

        switch (cursor.phase) {
            .start => unreachable,
            .done => break,
            .reject => return undo(summaries, units, replay.changed),
            inline .settled, .demanded, .planned => |phase| {
                const kind = comptime @field(Memo.Kind, @tagName(phase));
                const visit = @field(trace, @tagName(phase)).entries[cursor.visit];

                _ = scratch.reset(.retain_capacity);

                const value = try revisit(kind, scratch.allocator(), temporary, program, slots, summaries, units[cursor.body].?, cursor.body, memo, visit.state) orelse return undo(summaries, units, replay.changed);

                if (kind == .planned) {
                    try replacements.append(temporary, .{ .visit = cursor.visit, .value = value });
                } else if (!try Trace.agree(kind, scratch.allocator(), visit.value, value)) return undo(summaries, units, replay.changed);
            },
        }
    }

    const plans = try allocator.alloc(Plan, program.functions.count());
    var entry_plan: Plan = undefined;
    var first: usize = 0;
    var replacement: usize = 0;

    while (first < units.len) {
        const span = Shortcut.range(trace.planned.starts, replay.changed, first);
        const recorded = trace.planned.starts[first];

        for (first..span.end, 0..) |index, offset| {
            const target = if (index == plans.len) &entry_plan else &plans[index];

            target.* = switch (span.source) {
                .empty => .{ .flags = &.{} },
                .recorded => try trace.planned.entries[recorded + offset].value.plan().copy(allocator),
                .replacement => try replacements.items[replacement + offset].value.plan().copy(allocator),
            };
        }

        if (span.source == .replacement) replacement += span.end - first;

        first = span.end;
    }

    for (replacements.items) |change| trace.planned.entries[change.visit].value = change.value;

    @memcpy(trace.identities, replay.identities);

    return .{ .functions = plans, .entry = entry_plan };
}

/// The result body `index` reaches in a recorded state: the memo's when it has one, or a new analysis in that state.
fn revisit(comptime kind: Memo.Kind, temporary: std.mem.Allocator, lasting: std.mem.Allocator, program: ir.Program, slots: Slots, summaries: *Summaries, unit: *Unit, index: usize, memo: *Memo, state: []const u8) std.mem.Allocator.Error!?Memo.Result(kind) {
    if (memo.findReplay(kind, unit.identity, state)) |value| return value;

    const generated = @import("genz_options").generated_analysis;
    var restored: Growth.Store = undefined;
    const growth = if (generated) &restored else &unit.growth;

    if (!try Memo.restore(kind, temporary, state, summaries, index, unit.callees, growth)) return null;

    var analysis = try unit.initialize(temporary, lasting, program.functions, slots, summaries, growth, false);

    switch (kind) {
        .settled => {
            const result = try analysis.settle(memo.arena.allocator(), if (index < summaries.output.len) summaries.output[index].len else 0);

            return try memo.putOwnedSettled(memo.key, result.passed, result.output);
        },
        .demanded => {
            const result = try analysis.demand(memo.arena.allocator());

            if (generated and !analysis.grew) growth.* = try growth.copy(memo.arena.allocator());

            return try memo.putOwnedDemanded(memo.key, result.marks, growth, analysis.grew);
        },
        .planned => {
            const plan = try analysis.plan(memo.arena.allocator());

            return try memo.putOwnedPlan(memo.key, plan);
        },
    }
}

/// Clears what revisiting changed bodies left behind, as the fixpoint expects to start from.
fn undo(summaries: *Summaries, units: []const ?*Unit, changed: []const bool) ?Result {
    summaries.clearWants();

    // Source restores growth into the visit's local store. Only the seed revisits a unit's own store.
    if (@import("genz_options").generated_analysis) return null;

    for (units, changed) |entry, differs| if (differs) if (entry) |unit| {
        Growth.clear(&unit.growth);
    };

    return null;
}

fn prepare(allocator: std.mem.Allocator, unit: Function.Unit, body: ir.Block, called: []const u32) std.mem.Allocator.Error!*Unit {
    const result = try allocator.create(Unit);
    result.* = .{ .unit = unit, .body = body, .growth = Growth.init(allocator), .callees = called };
    result.unit.growth = &result.growth;

    return result;
}

/// Gives every body its identity, from the content the basis hashed where it did; bodies hash independently, so all
/// cores share the work.
fn identify(shared: [32]u8, contents: []const [32]u8, units: []const ?*Unit, identities: []Trace.Digest) void {
    const Hashing = struct {
        shared: [32]u8,
        contents: []const [32]u8,
        units: []const ?*Unit,
        identities: []Trace.Digest,
        next: std.atomic.Value(usize) = .init(0),
        fn run(work: *@This(), _: usize) void {
            while (true) {
                const index = work.next.fetchAdd(1, .monotonic);

                if (index >= work.units.len) return;

                const target = &work.identities[index];

                const unit = work.units[index] orelse {
                    target.* = @splat(0);

                    continue;
                };

                const content = if (index < work.contents.len) work.contents[index] else Identity.content(unit.unit.symbols, unit.unit.expressions, unit.body, unit.unit.input_type, unit.unit.output_type);

                target.* = Identity.combine(&work.shared, &content);
                unit.identity = target;
            }
        }
    };

    var work = Hashing{ .shared = shared, .contents = contents, .units = units, .identities = identities };

    @import("zx").parallel.spread(Hashing, &work, Hashing.run, units.len);
}
