const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const alignment = @import("alignment.zig");
const comparisons = @import("comparison.zig");
const rule = @import("generated_rx_mixed_history_start");

pub fn matches(state: *const State, previous: *const History.Retained, shape: *const [32]u8, initial: *const History.Checkpoint) bool {
    const Input = std.meta.Child(rule.Input);
    const Boundaries = std.meta.Child(@FieldType(Input, "boundary"));
    const Checkpoint = std.meta.Child(@FieldType(Boundaries, "before"));
    const Extent = std.meta.Child(@FieldType(Checkpoint, "extent"));
    const earlier_boundary = &previous.boundaries[0];
    const earlier_extent = alignment.extent(Extent, earlier_boundary);
    const current_extent = alignment.extent(Extent, initial);
    const earlier = previous.derived.dependencies;
    const current = state.graph;
    const earlier_paths = earlier.modules.items(.path);
    const current_paths = current.modules.items(.path);
    var borrowed: alignment.Borrowed = undefined;
    const types = borrowed.project(state, previous, &History.Checkpoint.zero, earlier_boundary, initial);

    const functions: comparisons.Range = .{
        .earlier = &previous.functions,
        .current = &state.functions,
        .first = 0,
        .end = initial.functions,
    };

    const input: Input = .{
        .inputs = &.{
            .earlier = &previous.shape,
            .current = shape,
            .earlier_count = earlier_paths.len,
            .current_count = current_paths.len,
        },
        .boundary = &.{
            .before = &checkpoint(Checkpoint, earlier_boundary, &earlier_extent),
            .after = &checkpoint(Checkpoint, initial, &current_extent),
        },
        .graph = &.{
            .earlier_order = std.mem.sliceAsBytes(earlier.order),
            .current_order = std.mem.sliceAsBytes(current.order),
            .earlier_paths = earlier_paths,
            .current_paths = current_paths,
            .shared_paths = earlier_paths.ptr == current_paths.ptr,
        },
        .alignment = &types,
        .functions = @ptrCast(&functions),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
}

fn checkpoint(comptime Target: type, value: *const History.Checkpoint, counts: @FieldType(Target, "extent")) Target {
    return .{ .types = std.mem.asBytes(&value.types), .origins = std.mem.asBytes(&value.origins), .extent = counts };
}
