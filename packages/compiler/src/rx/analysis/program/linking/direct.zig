const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const headers = @import("headers.zig");
const operands = @import("operands.zig");
const generated = @import("rx_options").generated_graph;

pub fn unit(builder: *Builder, span: zx.Span) Builder.Error!ir.ExprId {
    const type_id: ir.TypeId = @fromBackingInt(@as(u32, @intCast(@backingInt(ir.Scalar.void))));

    if (comptime !generated) return builder.seedExpression(.{ .type_id = type_id, .span = span, .value = .unit });

    const rule = @import("generated_rx_link_expression_row");
    const Input = std.meta.Child(rule.Input);
    const Row = std.meta.Child(@FieldType(Input, "row"));
    const storage = &builder.expressions;
    const id: ir.ExprId = @fromBackingInt(@as(u32, @intCast(storage.count())));

    try storage.reserveHeaders(builder.allocator, 1);

    const columns = headers.Tail.init(storage, 1);
    const slots = headers.lengthSlots(storage);
    const lengths: zx.memory.ColumnLengths = &slots;

    try operands.invoke(rule, .{
        .row = &.{
            .header = &columns.view(std.meta.Child(@FieldType(Row, "header"))),
            .metadata = &.{ .type_id = @backingInt(type_id), .span_start = span.start, .span_end = span.end },
            .kind = kindByte(.Unit),
            .payload = 0,
        },
        .extent = &.{ .target = @ptrCast(&lengths), .count = 1 },
    });

    return id;
}

fn kindByte(kind: std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"))) u8 {
    return @backingInt(kind);
}
