const std = @import("std");
const ir = @import("zx").ir;
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
    var arena = std.heap.ArenaAllocator.init(builder.allocator);

    defer arena.deinit();

    var bytes: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&bytes, arena.allocator());

    const input: Input = .{
        .row = &.{
            .metadata = &.{ .type_id = @backingInt(result_type), .span_start = span.start, .span_end = span.end },
            .kind = @backingInt(kind),
            .payload = @intCast(storage.call_functions.items.len),
        },
        .operands = &.{
            .function_id = @backingInt(function),
            .argument = @backingInt(argument),
            .stores = &.{
                .first = @intCast(storage.call_stores.items.len),
                .count = store_count,
            },
        },
    };

    const output = try invokeRule(generated, scratch.allocator(), input);

    storage.call_functions.appendAssumeCapacity(output.operands.function_id);
    storage.call_arguments.appendAssumeCapacity(output.operands.argument);
    storage.call_store_first.appendAssumeCapacity(output.operands.stores.first);
    storage.call_store_count.appendAssumeCapacity(output.operands.stores.count);
    storage.call_stores.items.len += output.operands.stores.count;

    headers.append(storage, output.row);

    return id;
}
