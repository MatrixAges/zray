const std = @import("std");
const ir = @import("zx").ir;
const Function = @import("function.zig");
const Level = @import("level.zig").Level;
const Growth = @import("growth.zig");
const Identity = @import("identity.zig");
const Trace = @import("trace.zig");
const Shortcut = @import("replay/shortcut.zig");
pub const Memo = @import("memo.zig");
const Bodies = @import("program/bodies.zig");
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

/// `exported` functions are also called from outside the program, so nothing is known about their input. A persistent
/// `memo` carries body analyses over from earlier programs; without one, repeated states only replay within this call.
pub fn analyze(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Basis, return_allocations: []const bool, persistent: ?*Memo) std.mem.Allocator.Error!Result {
    return analyzeWithConcurrency(allocator, workspace, program, exported, basis, return_allocations, persistent, false);
}

/// All allocators must be threadsafe, including shared parents and the exclusively borrowed memo.
pub fn analyzeConcurrent(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Basis, return_allocations: []const bool, persistent: ?*Memo) std.mem.Allocator.Error!Result {
    return analyzeWithConcurrency(allocator, workspace, program, exported, basis, return_allocations, persistent, true);
}

fn analyzeWithConcurrency(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Basis, return_allocations: []const bool, persistent: ?*Memo, comptime concurrent: bool) std.mem.Allocator.Error!Result {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    var local = Memo.init(workspace, false);

    defer local.deinit();

    const memo = persistent orelse &local;
    const temporary = scratch.allocator();
    const slots = basis.slots;
    var summary_memory = std.heap.ArenaAllocator.init(workspace);

    defer summary_memory.deinit();

    const topology = try Topology.collect(temporary, program);
    var summaries = try Summaries.create(summary_memory.allocator(), &program, basis, topology.active);

    summaries.return_allocations = return_allocations;

    var replay = Trace.Replay{ .allocator = temporary };

    defer replay.deinit();

    const identities = if (memo.persistent) hashed: {
        const shared = Identity.program(program, basis, return_allocations);
        const values = try Identity.bodies(temporary, &program, topology.active, &shared, basis.contents);

        if (memo.record_trace) {
            const previous = if (memo.trace) |*trace| trace else null;
            const key = Identity.combine(&shared, std.mem.sliceAsBytes(exported));

            replay = try .init(temporary, memo.arena.child_allocator, previous, key, values, topology.callees);
        }

        break :hashed values;
    } else &.{};

    const bodies = try Bodies.init(temporary, &program, topology.callees, identities);

    var state: @import("program/host.zig").Context = .{
        .allocator = allocator,
        .workspace = workspace,
        .temporary = temporary,
        .slots = slots,
        .summaries = &summaries,
        .bodies = &bodies,
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

    const temporary = scratch.allocator();
    const slots = basis.slots;
    const generated = @import("genz_options").generated_analysis;
    var summaries = Summaries.independent(basis);
    var unit = Bodies.Unit.init(temporary);
    const body = Bodies.View.at(&program, program.functions.count());

    if (generated) {
        var function = try unit.analyze(temporary, temporary, body, slots, &summaries, null, false);

        return @import("function/entry.zig").analyze(&function, allocator);
    }

    while (true) {
        var analysis = try unit.analyze(temporary, temporary, body, slots, &summaries, null, false);

        _ = try analysis.demand(temporary);

        if (!analysis.grew) break;
    }

    var analysis = try unit.analyze(temporary, temporary, body, slots, &summaries, null, false);

    return analysis.plan(allocator);
}

pub const Work = if (@import("genz_options").generated_analysis) @import("work.zig") else @import("work/seed.zig");

/// The plans of an analysis that takes the path of the trace it follows, known without walking it: every changed body,
/// analyzed again in each state the trace met it in, settles and demands as recorded, so every other body meets what
/// it met before. Only the plans of the changed bodies are new. Null, with the summaries and growth copies as they
/// were, when a changed body differs.
pub fn shortcut(allocator: std.mem.Allocator, workspace: std.mem.Allocator, temporary: std.mem.Allocator, slots: Slots, summaries: *Summaries, bodies: *const Bodies, active: []const bool, memo: *Memo, replay: *const Trace.Replay) std.mem.Allocator.Error!?Result {
    const trace = &memo.trace.?;
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    var replacements: std.ArrayList(Shortcut.Replacement) = .empty;
    var cursor: Shortcut = .{};
    var agreed = true;

    while (true) {
        cursor = cursor.next(active, trace, replay.changed, agreed);

        switch (cursor.phase) {
            .start => unreachable,
            .done => break,
            .reject => return undo(summaries, bodies.units, replay.changed),
            inline .settled, .demanded, .planned => |phase| {
                const kind = comptime @field(Memo.Kind, @tagName(phase));
                const visit = @field(trace, @tagName(phase)).entries[cursor.visit];

                _ = scratch.reset(.retain_capacity);

                const value = try revisit(kind, scratch.allocator(), temporary, slots, summaries, bodies, cursor.body, memo, visit.state) orelse {
                    agreed = false;

                    continue;
                };

                if (kind == .planned) {
                    try replacements.append(temporary, .{ .visit = @intCast(cursor.visit), .value = value });
                } else {
                    agreed = try Trace.agree(kind, scratch.allocator(), visit.value, value);
                }
            },
        }
    }

    return try Shortcut.publish(allocator, trace, replay, replacements.items);
}

/// The result body `index` reaches in a recorded state: the memo's when it has one, or a new analysis in that state.
fn revisit(comptime kind: Memo.Kind, temporary: std.mem.Allocator, lasting: std.mem.Allocator, slots: Slots, summaries: *Summaries, bodies: *const Bodies, index: usize, memo: *Memo, state: []const u8) std.mem.Allocator.Error!?Memo.Result(kind) {
    if (memo.findReplay(kind, &bodies.identities[index], state)) |value| return value;

    const generated = @import("genz_options").generated_analysis;
    var restored: Growth.Store = undefined;
    const growth = if (generated) &restored else &bodies.units[index].growth;

    if (!try Memo.restore(kind, temporary, state, summaries, index, bodies.callees[index], growth)) return null;

    var analysis = try bodies.analyze(temporary, lasting, slots, summaries, index, growth, false);

    switch (kind) {
        .settled => {
            const result = try analysis.settle(memo.arena.allocator(), if (index < summaries.output.len) summaries.output[index].len else 0);

            return try memo.putOwnedSettled(memo.key, result.passed, result.output);
        },
        .demanded => {
            const result = try analysis.demand(memo.arena.allocator());

            if (generated and !analysis.grew) growth.* = try @import("retain.zig").growth(memo.arena.allocator(), growth.*);

            return try memo.putOwnedDemanded(memo.key, result.marks, growth, analysis.grew);
        },
        .planned => {
            const plan = try analysis.plan(memo.arena.allocator());

            return try memo.putOwnedPlan(memo.key, plan);
        },
    }
}

/// Clears what revisiting changed bodies left behind, as the fixpoint expects to start from.
fn undo(summaries: *Summaries, units: []Bodies.Unit, changed: []const bool) ?Result {
    summaries.clearWants();

    // Source restores growth into the visit's local store. Only the seed revisits a unit's own store.
    if (@import("genz_options").generated_analysis) return null;

    for (units, changed) |*unit, differs| {
        if (differs) Growth.clear(&unit.growth);
    }

    return null;
}
