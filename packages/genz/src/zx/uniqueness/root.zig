const std = @import("std");
const ir = @import("zx").ir;
const Function = @import("function.zig");
const Identity = @import("identity.zig");
const Trace = @import("trace.zig");
pub const Memo = @import("memo.zig");
const Bodies = @import("program/bodies.zig");
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

    const prepared = if (@import("genz_options").generated_analysis)
        try @import("summaries/storage.zig").prepare(temporary, summary_memory.allocator(), &program, basis)

    else seed: {
        const calls = try @import("topology/seed.zig").collect(temporary, program);
        const summaries = try Summaries.createSeed(summary_memory.allocator(), &program, basis, calls.active);

        break :seed .{ .calls = calls, .summaries = summaries };
    };

    const topology = prepared.calls;
    var summaries = prepared.summaries;
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

    if (generated) return @import("program/visit/analysis.zig").entry(allocator, temporary, body, &unit, slots, &summaries);

    while (true) {
        var analysis = try unit.analyze(temporary, temporary, body, slots, &summaries, null, false);

        _ = try analysis.demand(temporary);

        if (!analysis.grew) break;
    }

    var analysis = try unit.analyze(temporary, temporary, body, slots, &summaries, null, false);

    return analysis.plan(allocator);
}

pub const Work = if (@import("genz_options").generated_analysis) @import("work.zig") else @import("work/seed.zig");
