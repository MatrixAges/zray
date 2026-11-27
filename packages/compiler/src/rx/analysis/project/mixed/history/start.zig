const std = @import("std");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const alignment = @import("alignment.zig");
const compare = @import("frontend").compare_ir;
const snapshot = @import("snapshot.zig");
const columns = @import("../../history/columns.zig");
const rule = @import("generated_rx_mixed_history_start");
const Input = std.meta.Child(rule.Input);
const Earlier = std.meta.Child(@typeInfo(@FieldType(Input, "earlier")).optional.child);
const Range = std.meta.Child(@FieldType(Earlier, "functions"));

pub fn begin(state: *State, previous: ?*const History.Retained, shape: *const [32]u8, initial: *History.Checkpoint) std.mem.Allocator.Error!bool {
    var storage: snapshot.Storage = undefined;
    const capture = storage.bind(state);
    const retained = previous orelse return execute(state.scratch.child_allocator, initial, &.{ .capture = &capture, .earlier = null });
    const boundary = &retained.boundaries[0];
    const checkpoint = columns.words(std.mem.asBytes(boundary));
    const earlier = &retained.derived.dependencies;
    const current = &state.graph;
    const earlier_paths = earlier.modules.items(.path);
    const current_paths = current.modules.items(.path);
    var borrowed: alignment.Borrowed = undefined;
    const types = borrowed.project(state, retained, &History.Checkpoint.zero, boundary, &storage.extent);
    const functions = compare.range(Range, &retained.functions, &state.functions, 0, @intCast(storage.extent.functions));

    return execute(state.scratch.child_allocator, initial, &.{
        .capture = &capture,
        .earlier = &.{
            .inputs = &.{
                .earlier = &retained.shape,
                .current = shape,
                .earlier_count = earlier_paths.len,
                .current_count = current_paths.len,
            },
            .checkpoint = @ptrCast(&checkpoint),
            .graph = &.{
                .earlier_order = std.mem.sliceAsBytes(earlier.order),
                .current_order = std.mem.sliceAsBytes(current.order),
                .earlier_paths = earlier_paths,
                .current_paths = current_paths,
                .shared_paths = earlier_paths.ptr == current_paths.ptr,
            },
            .alignment = &types,
            .functions = &functions,
        },
    });
}

fn execute(backing: std.mem.Allocator, target: *History.Checkpoint, input: *const Input) std.mem.Allocator.Error!bool {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    var buffer: [1024]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const result = rule.executeValue(scratch.allocator(), input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    snapshot.commit(target, result.checkpoint);

    return result.aligned;
}
