const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const rule = @import("generated_rx_mixed_history_publish");
const Input = std.meta.Child(rule.Input);

pub fn copy(state: *State, boundaries: []History.Checkpoint, previous: *const History.Retained, first: usize, end: usize, reused: *usize) void {
    const surfaces = std.mem.sliceAsBytes(state.finished.surfaces);
    const functions = std.mem.sliceAsBytes(state.finished.functions);
    const present = std.mem.sliceAsBytes(state.finished.present);
    const checkpoints = std.mem.sliceAsBytes(boundaries);
    const verified: []u64 = @as(*[1]u64, @ptrCast(&state.verified));
    const replayed: []u64 = @as(*[1]u64, @ptrCast(reused));

    const input: Input = .{
        .rows = @ptrCast(state.graph.order[first..end]),
        .first = first,
        .end = end,
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
        .counters = &.{
            .verified = @ptrCast(&verified),
            .verified_end = previous.boundaries[end].functions,
            .reused = @ptrCast(&replayed),
        },
        .checkpoints = &.{
            .earlier = std.mem.sliceAsBytes(previous.boundaries),
            .current = @ptrCast(&checkpoints),
            .width = @sizeOf(History.Checkpoint),
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}
