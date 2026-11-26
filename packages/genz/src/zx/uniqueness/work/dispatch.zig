const std = @import("std");
const zx = @import("zx");
const Ahead = @import("../ahead.zig");
const Memo = @import("../memo.zig");
const BodyRows = @import("../memo/body_rows.zig");
const Schedule = @import("../ahead/schedule.zig");
const Round = @import("round.zig");
const entry = @import("generated_uniqueness_work_dispatch");
const probe_entry = @import("generated_uniqueness_memo_probe");
const ProbeInput = std.meta.Child(probe_entry.Input);
const RowsType = std.meta.Child(@FieldType(ProbeInput, "rows"));
const SummariesType = std.meta.Child(@FieldType(ProbeInput, "summaries"));
const TableType = std.meta.Child(@FieldType(ProbeInput, "table"));
const EncodingState = std.meta.Child(@FieldType(ProbeInput, "state"));
pub const Advance = std.meta.Child(entry.Input);

pub fn run(ahead: *Ahead, memo: *Memo, comptime kind: Memo.Kind, advance: *const Advance) std.mem.Allocator.Error!Round.Claim {
    const allocator = memo.arena.allocator();

    const chosen = zx.columns.invoke(entry.executeValue, allocator, advance) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership work dispatch failed: {s}", .{@errorName(err)}),
    };

    const claim: Round.Claim = .{
        .visit = if (chosen.body) |body| .{ .body = @intCast(body) } else if (chosen.exhausted) .exhausted else .done,
        .pending = .{ .first = chosen.first, .second = chosen.second },
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
    const table_probe = if (use_memo) @field(memo, @tagName(kind)).probe(TableType, null) else undefined;
    var target: []u8 = &memo.key;
    var first: usize = 0;

    while (Schedule.scan(ahead.states, ahead.dirty, ahead.recursive, claim.pending, first, workers)) |pos| {
        const index: usize = @intCast(claim.pending.at(pos));
        first = pos + 1;

        if (use_memo) {
            const encoding = memo.encoding.binding(EncodingState);

            const input: ProbeInput = .{
                .rows = &body_rows,
                .summaries = &summary,
                .index = index,
                .table = &table_probe,
                .digest = @ptrCast(&target),
                .state = &encoding,
                .kind = @fromBackingInt(@backingInt(kind)),
            };

            const found = zx.columns.invoke(probe_entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("ownership work probe failed: {s}", .{@errorName(err)}),
            };

            memo.encoding.state_end = found.state.state_end;

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
