const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const alignment = @import("alignment.zig");
const comparisons = @import("comparison.zig");
const Snapshot = @import("snapshot.zig").Storage;
const rule = @import("generated_rx_mixed_history_start");
const Input = std.meta.Child(rule.Input);

pub fn begin(state: *const State, previous: ?*const History.Retained, shape: *const [32]u8, initial: *History.Checkpoint) bool {
    var storage: Snapshot = undefined;
    const capture = storage.bind(state, initial);
    const checkpoint = std.mem.asBytes(initial);
    const retained = previous orelse return execute(&.{ .capture = &capture, .checkpoint = checkpoint, .earlier = null });
    const boundary = &retained.boundaries[0];
    const earlier = &retained.derived.dependencies;
    const current = &state.graph;
    const earlier_paths = earlier.modules.items(.path);
    const current_paths = current.modules.items(.path);
    var borrowed: alignment.Borrowed = undefined;
    const types = borrowed.project(state, retained, &History.Checkpoint.zero, boundary, &storage.extent);

    const functions: comparisons.Range = .{
        .earlier = &retained.functions,
        .current = &state.functions,
        .first = 0,
        .end = @intCast(storage.extent.functions),
    };

    return execute(&.{
        .capture = &capture,
        .checkpoint = checkpoint,
        .earlier = &.{
            .inputs = &.{
                .earlier = &retained.shape,
                .current = shape,
                .earlier_count = earlier_paths.len,
                .current_count = current_paths.len,
            },
            .checkpoint = std.mem.asBytes(boundary),
            .graph = &.{
                .earlier_order = std.mem.sliceAsBytes(earlier.order),
                .current_order = std.mem.sliceAsBytes(current.order),
                .earlier_paths = earlier_paths,
                .current_paths = current_paths,
                .shared_paths = earlier_paths.ptr == current_paths.ptr,
            },
            .alignment = &types,
            .functions = @ptrCast(&functions),
        },
    });
}

fn execute(input: *const Input) bool {
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return rule.executeIn(scratch.allocator(), input) catch unreachable;
}
