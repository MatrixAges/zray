const std = @import("std");
const updates = @import("../function/updates.zig");
const zx = @import("zx");
const Ahead = @import("../ahead.zig");
const Memo = @import("../memo.zig");
const BodyRows = @import("../memo/body_rows.zig");
const Schedule = @import("../ahead/schedule.zig");
const Round = @import("round.zig");
const Work = @import("../work.zig");
const entry = @import("generated_uniqueness_work_dispatch");
const probe_entry = @import("generated_uniqueness_memo_probe");
const ProbeInput = std.meta.Child(probe_entry.Input);
const RowsType = std.meta.Child(@FieldType(ProbeInput, "rows"));
const SummariesType = std.meta.Child(@FieldType(ProbeInput, "summaries"));
const TableType = std.meta.Child(@FieldType(ProbeInput, "table"));
pub const Advance = std.meta.Child(entry.Input);

pub fn run(ahead: *Ahead, memo: *Memo, comptime kind: Memo.Kind, advance: *const Advance, work: *Work, frame: *const Round.Frame) std.mem.Allocator.Error!Round.Claim {
    var scratch_buf: [4096]u8 = undefined;
    var scratch = std.heap.ArenaAllocator.init(memo.arena.child_allocator);

    defer scratch.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, scratch.allocator());
    const allocator = fallback.allocator();

    const chosen = zx.columns.invoke(entry.executeValue, allocator, advance) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("ownership work dispatch failed: {s}", .{@errorName(err)}),
    };

    updates.commit(&.{}, frame.outputs, chosen.updates);

    for (chosen.dirty) |index| frame.dirty[index] = true;

    for (chosen.additions) |update| {
        work.slots[update.slot] = update.body;
        work.queued[update.body] = 1;
    }

    if (chosen.plan) |plan| {
        const target = frame.plans.?;
        const row = if (plan.entry) target.entry else &target.functions[plan.index];

        @memcpy(std.mem.asBytes(row), plan.fields);
    }

    if (chosen.dequeued) |index| work.queued[index] = 0;

    work.cursor = .{
        .head = chosen.cursor.head,
        .count = chosen.cursor.count,
        .budget = chosen.cursor.budget,
        .grew = chosen.cursor.grew,
    };

    const claim: Round.Claim = .{
        .visit = if (chosen.body) |body| .{ .body = @intCast(body) } else if (chosen.exhausted) .exhausted else .done,
        .pending = .{
            .first = work.slots[@as(usize, @intCast(chosen.pending_start))..][0..@intCast(chosen.pending_first)],
            .second = work.slots[0..@intCast(chosen.pending_second)],
        },
        .grew = chosen.grew,
        .prefetch = chosen.prefetch,
    };

    const pool = ahead.pool;
    const workers = pool.count();

    if (!claim.prefetch or workers == 0 or claim.pending.first.len == 0) return claim;

    const use_memo = !advance.following and (kind != .planned or memo.persistent);
    var views: BodyRows.Views(RowsType) = undefined;
    const body_rows = if (use_memo) ahead.memo_rows.view(RowsType, &views) else undefined;
    const summary = if (use_memo) BodyRows.summaries(SummariesType, ahead.summaries) else undefined;
    const table_probe = if (use_memo) @field(memo, @tagName(kind)).probe(TableType) else undefined;
    var first: usize = 0;
    var probe_scratch = std.heap.ArenaAllocator.init(memo.arena.child_allocator);

    defer probe_scratch.deinit();

    while (Schedule.scan(ahead.states, ahead.dirty, ahead.recursive, claim.pending, first, workers)) |pos| {
        const index: usize = @intCast(claim.pending.at(pos));

        first = pos + 1;

        if (use_memo) {
            _ = probe_scratch.reset(.retain_capacity);

            const input: ProbeInput = .{
                .rows = &body_rows,
                .summaries = &summary,
                .index = index,
                .table = &table_probe,
                .kind = @fromBackingInt(@backingInt(kind)),
            };

            const found = zx.columns.invoke(probe_entry.executeValue, probe_scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("ownership work probe failed: {s}", .{@errorName(err)}),
            };

            try memo.encoding.capture(found.state);

            @memcpy(&memo.key, found.digest);

            if (found.row != null) {
                _ = Schedule.transition(ahead.states, index, .Hold);

                continue;
            }
        }

        _ = Schedule.transition(ahead.states, index, .Queue);

        if (!pool.submit(@intCast(index))) {
            _ = Schedule.transition(ahead.states, index, .Withdraw);

            return claim;
        }
    }

    return claim;
}
