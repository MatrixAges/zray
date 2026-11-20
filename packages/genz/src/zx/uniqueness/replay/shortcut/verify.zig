const std = @import("std");
const zx = @import("zx");
const Analysis = @import("../../root.zig");
const Context = @import("../../program/host.zig").Context;
const compute = @import("../../program/visit/compute.zig");
const Memo = @import("../../memo.zig");
const Growth = @import("../../growth.zig");
const Trace = @import("../../trace.zig");
const Cursor = @import("../shortcut.zig");
const Replacements = @import("replacements.zig");
const sequence = @import("generated_uniqueness_shortcut_visit");
const Error = std.mem.Allocator.Error;

/// Recomputes changed visits in their recorded state before allowing the trace to publish.
pub fn run(ctx: *Context) Error!?Analysis.Result {
    const trace = &ctx.memo.trace.?;
    var scratch = std.heap.ArenaAllocator.init(ctx.workspace);

    defer scratch.deinit();

    var replacements: Replacements = .{};
    var cursor: Cursor = .{};
    var agreed = true;

    while (true) {
        cursor = cursor.next(ctx.calls.active, trace, ctx.replay.changed, agreed);

        switch (cursor.phase) {
            .start => unreachable,
            .done => return try Cursor.publish(ctx.allocator, trace, ctx.replay, replacements.rows()),
            .reject => {
                ctx.summaries.clearWants();

                return null;
            },
            inline .settled, .demanded, .planned => |phase| {
                const kind = comptime @field(Memo.Kind, @tagName(phase));

                agreed = try visit(kind, ctx, trace, &scratch, &replacements, cursor);
            },
        }
    }
}

fn steps(comptime kind: Memo.Kind, comptime recompute: bool) []const std.meta.Child(sequence.Output) {
    return zx.staticSequence(sequence, &.{
        .phase = switch (kind) {
            .settled => .Settled,
            .demanded => .Demanded,
            .planned => .Planned,
        },
        .recompute = recompute,
    });
}

fn visit(comptime kind: Memo.Kind, ctx: *Context, trace: *const Trace, scratch: *std.heap.ArenaAllocator, replacements: *Replacements, cursor: Cursor) Error!bool {
    const previous = &@field(trace, @tagName(kind)).entries[cursor.visit];
    var current: ?Memo.Result(kind) = null;
    var agreed = true;

    inline for (comptime steps(kind, false)) |step| switch (step) {
        .ResetScratch => _ = scratch.reset(.retain_capacity),
        .FindRecord => current = ctx.memo.findReplay(kind, &ctx.bodies.identities[cursor.body], previous.state),
        .RecoverOnMiss => if (current == null) {
            current = try recover(kind, ctx, cursor.body, previous.state, scratch.allocator()) orelse return false;
        },
        .CompareResult => agreed = try Trace.agree(kind, scratch.allocator(), previous.value, current.?),
        .StagePlan => try replacements.append(ctx.temporary, .{ .visit = @intCast(cursor.visit), .value = current.? }),
        else => unreachable,
    };

    return agreed;
}

fn recover(comptime kind: Memo.Kind, ctx: *Context, body: usize, state: []const u8, scratch: std.mem.Allocator) Error!?Memo.Result(kind) {
    const owner = ctx.memo.arena.allocator();
    var growth: Growth.Store = undefined;
    var record: Memo.Result(kind) = undefined;

    inline for (comptime steps(kind, true)) |step| switch (step) {
        .RestoreState => if (!try Memo.restore(kind, scratch, state, ctx.summaries, body, ctx.bodies.callees[body], &growth)) return null,
        .Analyze => {
            const result = try compute.run(kind, .{
                .bodies = ctx.bodies,
                .slots = ctx.slots,
                .summaries = ctx.summaries,
                .body = body,
                .growth = &growth,
                .scratch = scratch,
                .lasting = ctx.temporary,
                .owner = owner,
            });

            record = result.record;
        },
        .RetainRestoredGrowth => if (!record.grew) {
            const retained = try @import("../../retain.zig").growth(owner, growth);
            record.normalized = retained.normalized;
            record.renewed = retained.renewed;
        },
        .SaveRecord => record = try ctx.memo.putVisit(kind, record, true),
        else => unreachable,
    };

    return record;
}
