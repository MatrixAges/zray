const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../program/builder.zig");
const Range = @import("../../program/linking/operands/range.zig");
const generated = @import("rx_options").generated_graph;

pub fn append(builder: *Builder, type_id: ir.TypeId, names: []const []const u8, canonical: []const []const u8, evaluation: []const u32, span: zx.Span) std.mem.Allocator.Error!ir.ExprId {
    const storage = &builder.expressions;
    const count = evaluation.len;

    try storage.reserveObject(builder.allocator, count, count);

    const payload = if (comptime generated)
        try publish(storage, names, canonical, evaluation)
    else
        seed(storage, names, canonical, evaluation);

    return @fromBackingInt(storage.appendHeader(.Object, payload, type_id, span));
}

fn publish(storage: *ir.ExpressionStorage, names: []const []const u8, canonical: []const []const u8, evaluation: []const u32) std.mem.Allocator.Error!usize {
    const rule = @import("generated_rx_store_initializer_object");
    const Input = std.meta.Child(rule.Input);
    const count = evaluation.len;
    const indices = storage.object_field_indices.unusedCapacitySlice()[0..count];
    const fields = std.mem.sliceAsBytes(storage.object_field_values.unusedCapacitySlice()[0..count]);
    const values = std.mem.sliceAsBytes(storage.object_evaluation_values.unusedCapacitySlice()[0..count]);
    const field_range = Range.init(storage, "object", storage.object_field_indices.items.len);
    const evaluation_range = Range.init(storage, "object_evaluation", storage.object_evaluation_values.items.len);

    const input: Input = .{
        .indices = &.{ .source = names, .canonical = canonical, .positions = @ptrCast(&indices) },
        .values = &.{ .source = std.mem.sliceAsBytes(evaluation), .fields = @ptrCast(&fields), .evaluation = @ptrCast(&values) },
        .fields = &field_range.view(std.meta.Child(@FieldType(Input, "fields"))),
        .evaluation = &evaluation_range.view(std.meta.Child(@FieldType(Input, "evaluation"))),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const payload = storage.object_first.items.len;

    storage.object_first.items.len += 1;
    storage.object_count.items.len += 1;
    storage.object_evaluation_first.items.len += 1;
    storage.object_evaluation_count.items.len += 1;
    storage.object_field_indices.items.len += count;
    storage.object_field_values.items.len += count;
    storage.object_evaluation_values.items.len += count;

    return payload;
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
