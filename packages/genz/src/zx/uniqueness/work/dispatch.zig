const std = @import("std");
const zx = @import("zx");
const Ahead = @import("../ahead.zig");
const Memo = @import("../memo.zig");
const BodyRows = @import("../memo/body_rows.zig");
const Round = @import("round.zig");
const entry = @import("generated_uniqueness_work_dispatch");
const Input = std.meta.Child(entry.Input);
const Prefetch = std.meta.Child(@FieldType(Input, "prefetch"));
const Window = std.meta.Child(@FieldType(Prefetch, "window"));
const Offer = std.meta.Child(@typeInfo(@FieldType(Prefetch, "memo")).optional.child);
const Body = std.meta.Child(@FieldType(Offer, "rows"));
pub const Advance = std.meta.Child(@typeInfo(@FieldType(Input, "round")).optional.child);

pub fn run(ahead: *Ahead, memo: *Memo, comptime kind: Memo.Kind, advance: *const Advance) std.mem.Allocator.Error!Round.Claim {
    const pool = ahead.pool;
    const workers = pool.count();
    const table = &@field(memo, @tagName(kind));
    const counters: []u32 = &pool.ring.counters;
    const flags = std.mem.sliceAsBytes(ahead.dirty);
    const target: []u8 = &memo.key;
    const allocator = memo.arena.allocator();
    var views: BodyRows.Views(Body) = undefined;
    const use_memo = workers != 0 and !advance.following and (kind != .planned or memo.persistent);
    const summary = if (use_memo) BodyRows.summaries(std.meta.Child(@FieldType(Offer, "summaries")), ahead.summaries) else undefined;

    const offer: Offer = if (use_memo) .{
        .rows = &ahead.memo_rows.view(Body, &views),
        .summaries = &summary,
        .kind = @fromBackingInt(@backingInt(kind)),
        .table = &table.probe(std.meta.Child(@FieldType(Offer, "table")), null),
        .order = &.{ .indices = @ptrCast(&memo.encoding.order.items), .scratch = @ptrCast(&memo.encoding.order) },
        .digest = @ptrCast(&target),
    } else undefined;

    var window: Window = .{
        .words = @ptrCast(&ahead.states),
        .dirty = @ptrCast(&flags),
        .recursive = ahead.recursive,
        .indices = &.{},
        .wrapped = &.{},
        .first = 0,
        .workers = workers,
    };

    var round: ?*const Advance = advance;
    var claim: Round.Claim = undefined;

    while (true) {
        const encoding = memo.encoding.binding(std.meta.Child(@FieldType(Prefetch, "encoding")));

        const input: Input = .{
            .round = round,
            .prefetch = &.{
                .window = &window,
                .channel = &.{ .counters = @ptrCast(&counters), .ring = @ptrCast(&pool.ring.ring) },
                .encoding = &encoding,
                .memo = if (use_memo) &offer else null,
                .needs_start = pool.started < pool.threads.len,
            },
        };

        const result = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("ownership work dispatch failed: {s}", .{@errorName(err)}),
        };

        if (result.claim) |chosen| {
            window.indices = chosen.first;
            window.wrapped = chosen.second;

            claim = .{
                .visit = if (chosen.body) |body| .{ .body = @intCast(body) } else if (chosen.exhausted) .exhausted else .done,
                .pending = .{ .first = chosen.first, .second = chosen.second },
                .grew = chosen.grew,
                .prefetch = chosen.prefetch,
            };
        }

        const offered = result.offered orelse return claim;
        memo.encoding.state_end = offered.encoding.state_end;

        const pending = offered.pending orelse return claim;

        pool.publishReserved(pending.position, pending.index);

        round = null;
        window.first = offered.next;
    }
}
