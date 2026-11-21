const std = @import("std");
const Ahead = @import("../ahead.zig");
const Memo = @import("../memo.zig");
const BodyRows = @import("../memo/body_rows.zig");
const Window = @import("../work/round.zig").Window;
const offering = @import("generated_uniqueness_ahead_request");
const Parameter = @typeInfo(@TypeOf(offering.executeState)).@"fn".param_types[1].?;
const indirect = @typeInfo(Parameter) == .pointer;
const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
const Offer = std.meta.Child(@typeInfo(@FieldType(Input, "memo")).optional.child);
const Body = std.meta.Child(@FieldType(Offer, "rows"));
const Error = std.mem.Allocator.Error;

pub fn run(ahead: *Ahead, memo: *Memo, comptime kind: Memo.Kind, indices: Window, workers: usize) Error!void {
    const pool = ahead.pool;
    const table = &@field(memo, @tagName(kind));
    const counters: []u32 = &pool.ring.counters;
    const flags = std.mem.sliceAsBytes(ahead.dirty);
    const target: []u8 = &memo.key;
    const allocator = memo.arena.allocator();
    var views: BodyRows.Views(Body) = undefined;
    var first: usize = 0;
    const summary = BodyRows.summaries(std.meta.Child(@FieldType(Offer, "summaries")), ahead.summaries);

    const offer: Offer = .{
        .rows = &ahead.memo_rows.view(Body, &views),
        .summaries = &summary,
        .kind = @fromBackingInt(@backingInt(kind)),
        .table = &table.probe(std.meta.Child(@FieldType(Offer, "table")), null),
        .order = &.{ .indices = @ptrCast(&memo.encoding.order.items), .scratch = @ptrCast(&memo.encoding.order) },
        .digest = @ptrCast(&target),
    };

    while (true) {
        const input: Input = .{
            .window = .{
                .words = @ptrCast(&ahead.states),
                .dirty = @ptrCast(&flags),
                .recursive = .{ .items = ahead.recursive, .storage = .plain },
                .indices = .{ .items = indices.first, .storage = .plain },
                .wrapped = .{ .items = indices.second, .storage = .plain },
                .first = first,
                .workers = workers,
            },
            .channel = &.{ .counters = @ptrCast(&counters), .ring = @ptrCast(&pool.ring.ring) },
            .encoding = memo.encoding.binding(),
            .memo = if (kind != .planned or memo.persistent) &offer else null,
            .needs_start = pool.started < pool.threads.len,
        };

        const result = offering.executeState(allocator, if (indirect) &input else input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("ownership prefetch failed: {s}", .{@errorName(err)}),
        };

        memo.encoding.state_end = result.encoding.state_end;

        const pending = result.pending orelse return;

        pool.publishReserved(pending.position, pending.index);

        first = @intCast(result.next);
    }
}
