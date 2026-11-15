const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../program/builder.zig");

pub fn append(builder: *Builder, type_id: ir.TypeId, names: []const []const u8, canonical: []const []const u8, evaluation: []const u32, span: zx.Span) std.mem.Allocator.Error!ir.ExprId {
    const storage = &builder.expressions;
    const count = evaluation.len;

    try storage.reserveObject(builder.allocator, count, count);
    try positions(names, canonical, storage.object_field_indices.unusedCapacitySlice()[0..count]);

    const payload = ir.ExpressionStorage.aggregate_payload.objectHeader(storage, count, count);

    storage.object_field_indices.items.len += count;

    storage.object_field_values.appendSliceAssumeCapacity(evaluation);
    storage.object_evaluation_values.appendSliceAssumeCapacity(evaluation);

    return @fromBackingInt(storage.appendHeader(.Object, payload, type_id, span));
}

fn positions(names: []const []const u8, canonical: []const []const u8, target: []u32) std.mem.Allocator.Error!void {
    if (names.len == 1) {
        target[0] = 0;

        return;
    }

    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_store_field_positions");
        const input: std.meta.Child(rule.Input) = .{ .source = names, .canonical = canonical, .positions = @ptrCast(&target) };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };
    }

    for (names, target) |name, *position| position.* = @intCast(std.sort.binarySearch([]const u8, canonical, name, compare).?);
}

fn compare(left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}
