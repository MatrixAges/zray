const std = @import("std");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const Borrowed = @import("admit.zig").Borrowed;
const columns = @import("../../history/columns.zig");
const rule = @import("generated_rx_mixed_history_replay");
const Input = std.meta.Child(rule.Input);

pub fn run(state: *State, previous: *const History.Retained, prefix: *const Borrowed, boundaries: []History.Checkpoint, first: usize, end: usize, reused: *usize) std.mem.Allocator.Error!usize {
    const graph = &state.graph;
    const order = columns.words(std.mem.sliceAsBytes(graph.order));
    const surfaces = std.mem.sliceAsBytes(state.finished.surfaces);
    const functions = std.mem.sliceAsBytes(state.finished.functions);
    const present = std.mem.sliceAsBytes(state.finished.present);
    const checkpoints = std.mem.sliceAsBytes(boundaries);
    const verified = columns.wordTarget(std.mem.asBytes(&state.verified));
    const replayed = columns.wordTarget(std.mem.asBytes(reused));

    const input: Input = .{
        .window = &.{
            .order = @ptrCast(&order),
            .first = first,
            .end = end,
            .entry = graph.entry,
            .sources = &.{ .zx_count = graph.sources.zx_count, .rx_end = graph.sources.rx_end },
            .history = &prefix.history,
        },
        .transfer = &.{ .allocator = @ptrCast(&state.allocator), .group = @ptrCast(&prefix.group) },
        .publication = &.{
            .rows = @ptrCast(&order),
            .modules = &.{
                .surfaces = &.{
                    .earlier = std.mem.sliceAsBytes(previous.finished.surfaces),
                    .current = @ptrCast(&surfaces),
                    .width = @sizeOf(std.meta.Elem(@TypeOf(state.finished.surfaces))),
                },
                .functions = &.{
                    .earlier = std.mem.sliceAsBytes(previous.finished.functions),
                    .current = @ptrCast(&functions),
                    .width = @sizeOf(std.meta.Elem(@TypeOf(state.finished.functions))),
                },
                .present = &.{
                    .earlier = std.mem.sliceAsBytes(previous.finished.present),
                    .current = @ptrCast(&present),
                    .width = @sizeOf(bool),
                },
                .available = previous.finished.present,
            },
            .counters = &.{ .verified = @ptrCast(&verified), .reused = @ptrCast(&replayed), .reused_before = reused.* },
            .checkpoints = &.{
                .earlier = std.mem.sliceAsBytes(previous.boundaries),
                .current = @ptrCast(&checkpoints),
                .width = @sizeOf(History.Checkpoint),
            },
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const position = rule.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return @intCast(position);
}
