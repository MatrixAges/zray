const std = @import("std");
const Analysis = @import("../../root.zig");
const Context = @import("../../program/host.zig").Context;
const compute = @import("../../program/visit/compute.zig");
const Memo = @import("../../memo.zig");
const Growth = @import("../../growth.zig");
const Cursor = @import("../shortcut.zig");
const Replacements = @import("replacements.zig");
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
    var recovered: ?u32 = null;

    while (true) {
        var prepared = try scan.advance(ctx, trace, &scratch, staged.allocator(), &replacements, cursor, recovered);

        cursor = prepared.cursor;

        switch (cursor.phase) {
            .start => unreachable,
            .done => return try Cursor.publish(ctx.allocator, trace, ctx.replay, replacements.rows(), ctx.calls.active),
            .reject => return null,
            inline .settled, .demanded, .planned => |phase| {
                const kind = comptime @field(Memo.Kind, @tagName(phase));

                recovered = try recover(kind, ctx, cursor.body, &prepared.growth, scratch.allocator());
            },
        }
    }
}

fn recover(comptime kind: Memo.Kind, ctx: *Context, body: usize, growth: *Growth.Store, scratch: std.mem.Allocator) Error!u32 {
    const result = try compute.run(kind, false, .{
        .bodies = ctx.bodies,
        .slots = ctx.slots,
        .summaries = ctx.summaries,
        .body = body,
        .growth = growth,
        .scratch = scratch,
        .lasting = ctx.roundMemory(),
        .owner = ctx.memo.arena.allocator(),
        .restored_growth = kind == .demanded,
        .memo = ctx.memo,
    });

    return result.row.?;
}
