const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../program/builder.zig");

pub fn append(builder: *Builder, type_id: ir.TypeId, names: []const []const u8, canonical: []const []const u8, evaluation: []const u32, span: zx.Span) std.mem.Allocator.Error!ir.ExprId {
    const storage = &builder.expressions;
    const count = evaluation.len;

    try storage.reserveObject(builder.allocator, count, count);

    const payload = seed(storage, names, canonical, evaluation);

    return @fromBackingInt(storage.appendHeader(.Object, payload, type_id, span));
}

fn seed(storage: *ir.ExpressionStorage, names: []const []const u8, canonical: []const []const u8, evaluation: []const u32) usize {
    const count = evaluation.len;
    const positions = storage.object_field_indices.unusedCapacitySlice()[0..count];
    const payload = ir.ExpressionStorage.aggregate_payload.objectHeader(storage, count, count);

    for (names, positions) |name, *position| position.* = @intCast(std.sort.binarySearch([]const u8, canonical, name, compare).?);

    storage.object_field_indices.items.len += count;

    storage.object_field_values.appendSliceAssumeCapacity(evaluation);
    storage.object_evaluation_values.appendSliceAssumeCapacity(evaluation);

    return payload;
}

fn compare(left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}
