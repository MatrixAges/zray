const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../builder.zig");
const invokeRule = @import("../operands.zig").invoke;
const headers = @import("../headers.zig");
const generated = @import("generated_rx_link_call");
const operands: []const []const u8 = &.{ "call_functions", "call_arguments", "call_store_first", "call_store_count" };

pub fn invoke(builder: *Builder, function: ir.FunctionId, argument: ir.ExprId, result_type: ir.TypeId, stores: []const u32) Builder.Error!ir.ExprId {
    if (comptime @import("rx_options").generated_graph) return publish(builder, function, argument, result_type, stores.len);

    return builder.seedExpression(.{
        .type_id = result_type,
        .span = builder.expressionSpan(argument),
        .value = .{ .call = .{ .function = function, .argument = argument, .stores = stores } },
    });
}

pub fn prepare(builder: *Builder, count: usize) std.mem.Allocator.Error![]u32 {
    const storage = &builder.expressions;

    try storage.reserveHeaders(builder.allocator, 1);
    try storage.reserveColumns(builder.allocator, operands, 1);
    try storage.reserveColumns(builder.allocator, &.{"call_stores"}, count);

    return storage.call_stores.unusedCapacitySlice()[0..count];
}

pub fn publish(builder: *Builder, function: ir.FunctionId, argument: ir.ExprId, result_type: ir.TypeId, store_count: usize) Builder.Error!ir.ExprId {
    const storage = &builder.expressions;
    const id: ir.ExprId = @fromBackingInt(@as(u32, @intCast(storage.count())));
    const span = builder.expressionSpan(argument);
    const kind: std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds")) = .Call;
    const Input = std.meta.Child(generated.Input);
    const Row = std.meta.Child(@FieldType(Input, "row"));
    const Header = std.meta.Child(@FieldType(Row, "header"));
    const header = headers.Tail.init(storage, 1);
    const functions: []u32 = storage.call_functions.unusedCapacitySlice()[0..1];
    const arguments: []u32 = storage.call_arguments.unusedCapacitySlice()[0..1];
    const firsts: []u32 = storage.call_store_first.unusedCapacitySlice()[0..1];
    const counts: []u32 = storage.call_store_count.unusedCapacitySlice()[0..1];
    var operand_slots: [operands.len]*usize = undefined;

    inline for (operands, &operand_slots) |name, *slot| slot.* = &@field(storage, name).items.len;

    const header_slots = headers.lengthSlots(storage);
    const operand_lengths: zx.memory.ColumnLengths = &operand_slots;
    const store_lengths: zx.memory.ColumnLengths = &.{&storage.call_stores.items.len};
    const header_lengths: zx.memory.ColumnLengths = &header_slots;

    const input: Input = .{
        .row = &.{
            .header = &header.view(Header),
            .metadata = &.{ .type_id = @backingInt(result_type), .span_start = span.start, .span_end = span.end },
            .kind = @backingInt(kind),
            .payload = @intCast(storage.call_functions.items.len),
        },
        .operands = &.{
            .functions = @ptrCast(&functions),
            .arguments = @ptrCast(&arguments),
            .function_id = @backingInt(function),
            .argument = @backingInt(argument),
        },
        .stores = &.{
            .range = &.{
                .firsts = @ptrCast(&firsts),
                .counts = @ptrCast(&counts),
                .first = @intCast(storage.call_stores.items.len),
            },
            .count = store_count,
        },
        .operands_extent = &.{ .target = @ptrCast(&operand_lengths), .count = 1 },
        .stores_lengths = @ptrCast(&store_lengths),
        .header_extent = &.{ .target = @ptrCast(&header_lengths), .count = 1 },
    };

    try invokeRule(generated, input);

    return id;
}
