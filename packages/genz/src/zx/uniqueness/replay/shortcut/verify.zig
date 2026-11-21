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
const scan = @import("scan.zig");
const Error = std.mem.Allocator.Error;

/// Recomputes changed visits in their recorded state before allowing the trace to publish.
pub fn run(ctx: *Context) Error!?Analysis.Result {
    const trace = &ctx.memo.trace.?;
    var scratch = std.heap.ArenaAllocator.init(ctx.workspace);
    var staged = std.heap.ArenaAllocator.init(ctx.workspace);

    defer scratch.deinit();
    defer staged.deinit();

    var replacements: Replacements = .{};
    var cursor: Cursor = .{};
    var agreed = true;

    while (true) {
        cursor = try scan.advance(ctx, trace, &scratch, staged.allocator(), &replacements, cursor, agreed);

        switch (cursor.phase) {
            .start => unreachable,
            .done => return try Cursor.publish(ctx.allocator, trace, ctx.replay, replacements.rows(), ctx.calls.active),
            .reject => return null,
            inline .settled, .demanded, .planned => |phase| {
                const kind = comptime @field(Memo.Kind, @tagName(phase));

                agreed = try visit(kind, ctx, trace, &scratch, staged.allocator(), &replacements, cursor);
            },
        }
    }
}

fn visit(comptime kind: Memo.Kind, ctx: *Context, trace: *const Trace, scratch: *std.heap.ArenaAllocator, staged: std.mem.Allocator, replacements: *Replacements, cursor: Cursor) Error!bool {
    const previous = &@field(trace, @tagName(kind)).entries[cursor.visit];

    _ = scratch.reset(.retain_capacity);

    const value = try recover(kind, ctx, cursor.body, previous.state, scratch.allocator()) orelse return false;

    if (kind != .planned) return Trace.agree(kind, scratch.allocator(), previous.value, value);
    try replacements.append(staged, .{ .visit = @intCast(cursor.visit), .value = value });

    return true;
}

fn recover(comptime kind: Memo.Kind, ctx: *Context, body: usize, state: []const u8, scratch: std.mem.Allocator) Error!?Memo.Result(kind) {
    const owner = ctx.memo.arena.allocator();
    var growth: Growth.Store = undefined;
    var record: Memo.Result(kind) = undefined;

    inline for (comptime zx.staticSequence(sequence, {})) |step| switch (step) {
        .RestoreState => if (!try Memo.restore(kind, scratch, state, ctx.summaries, body, ctx.bodies.callees[body], &growth)) return null,
        .Analyze => {
            const result = try compute.run(kind, false, .{
                .bodies = ctx.bodies,
                .slots = ctx.slots,
                .summaries = ctx.summaries,
                .body = body,
                .growth = &growth,
                .scratch = scratch,
                .lasting = ctx.roundMemory(),
                .owner = owner,
                .restored_growth = kind == .demanded,
            });

            record = result.record;
        },
        .SaveRecord => record = try ctx.memo.putVisit(kind, record, true),
    };

    return record;
}
