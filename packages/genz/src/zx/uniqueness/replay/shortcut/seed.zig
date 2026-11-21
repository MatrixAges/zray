const std = @import("std");
const Ownership = @import("../../root.zig");
const Growth = @import("../../growth.zig");
const Trace = @import("../../trace.zig");
const Shortcut = @import("../shortcut.zig");
const Memo = Ownership.Memo;
const Bodies = @import("../../program/bodies.zig");
const Slots = Ownership.Slots;
const Summaries = Ownership.Summaries;
const Result = Ownership.Result;

/// The plans of an analysis that takes the path of the trace it follows, known without walking it: every changed body,
/// analyzed again in each state the trace met it in, settles and demands as recorded, so every other body meets what
/// it met before. Only the plans of the changed bodies are new. Null, with the summaries and growth copies as they
/// were, when a changed body differs.
pub fn run(allocator: std.mem.Allocator, workspace: std.mem.Allocator, temporary: std.mem.Allocator, slots: Slots, summaries: *Summaries, bodies: *const Bodies, active: []const bool, memo: *Memo, replay: *const Trace.Replay) std.mem.Allocator.Error!?Result {
    const trace = &memo.trace.?;
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    var replacements: std.ArrayList(Shortcut.Replacement) = .empty;
    var cursor: Shortcut = .{};
    var agreed = true;

    while (true) {
        cursor = cursor.next(active, trace, replay.changed, agreed, summaries);

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

    return try Shortcut.publish(allocator, trace, replay, replacements.items, active);
}

/// The result body `index` reaches in a recorded state: the memo's when it has one, or a new analysis in that state.
fn revisit(comptime kind: Memo.Kind, temporary: std.mem.Allocator, lasting: std.mem.Allocator, slots: Slots, summaries: *Summaries, bodies: *const Bodies, index: usize, memo: *Memo, state: []const u8) std.mem.Allocator.Error!?Memo.Result(kind) {
    if (memo.findReplay(kind, &bodies.identities[index], state)) |value| return value;

    const growth = &bodies.units[index].growth;

    if (!try Memo.restore(kind, temporary, state, summaries, index, bodies.callees[index], growth)) return null;

    var analysis = try bodies.analyze(temporary, lasting, slots, summaries, index, growth, false);

    switch (kind) {
        .settled => {
            const result = try analysis.settle(memo.arena.allocator(), if (index < summaries.output.len) summaries.output[index].len else 0);

            return try memo.putOwnedSettled(memo.key, result.passed, result.output);
        },
        .demanded => {
            const result = try analysis.demand(memo.arena.allocator());

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

    for (units, changed) |*unit, differs| {
        if (differs) Growth.clear(&unit.growth);
    }

    return null;
}
