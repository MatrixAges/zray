const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../builder.zig");
const Writer = @import("../../control/writer.zig");
const Binding = @import("../../../store.zig").Binding;
const Columns = @import("../../../store/bindings.zig").Columns;
const headers = @import("../headers.zig");
const rule = @import("generated_rx_link_store_get");
const Input = std.meta.Child(rule.Input);

pub fn publish(builder: *Builder, writer: *Writer, cursor: *Writer.Cursor, getters: []const Binding, span: zx.Span) Builder.Error!void {
    const count = getters.len;
    const expressions = &builder.expressions;
    const symbols = &builder.symbols;
    const fields = @typeInfo(ir.SymbolStorage).@"struct".field_names;

    if (count > std.math.maxInt(u32) - symbols.count()) return error.OutOfMemory;
    try expressions.reserveColumns(builder.allocator, &.{"stores"}, count);

    const slots = expressions.stores.unusedCapacitySlice()[0..count];

    try @import("../../store/bind.zig").reads(builder, getters, slots);
    try expressions.reserveHeaders(builder.allocator, count);

    inline for (fields) |name| try @field(symbols, name).ensureUnusedCapacity(builder.allocator, count);

    try builder.bindings.ensureUnusedCapacity(builder.allocator, count);

    const getters_view = Columns.init(getters);
    const header = headers.Tail.init(expressions, count);
    const names = symbols.names.unusedCapacitySlice()[0..count];
    const types = symbols.types.unusedCapacitySlice()[0..count];
    const starts = symbols.span_start.unusedCapacitySlice()[0..count];
    const ends = symbols.span_end.unusedCapacitySlice()[0..count];
    const ownership = std.mem.sliceAsBytes(symbols.ownership.unusedCapacitySlice()[0..count]);
    const bindings = builder.bindings.unusedCapacitySlice()[0..count];
    const cells = cursor.cells();
    const Expression = std.meta.Child(@FieldType(Input, "expressions"));
    const Constants = std.meta.Child(@FieldType(Input, "constants"));
    const Kind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));

    const input: Input = .{
        .getters = &getters_view.view(std.meta.Child(@FieldType(Input, "getters"))),
        .span = &.{ .start = span.start, .end = span.end },
        .expressions = &.{
            .header = &header.view(std.meta.Child(@FieldType(Expression, "header"))),
            .first_payload = @intCast(expressions.stores.items.len),
            .kind = @backingInt(Kind.StoreGet),
        },
        .symbols = &.{
            .names = @ptrCast(&names),
            .types = @ptrCast(&types),
            .starts = @ptrCast(&starts),
            .ends = @ptrCast(&ends),
            .ownership = @ptrCast(&ownership),
            .copy_tag = @backingInt(ir.SymbolTable.Ownership.Copy),
        },
        .constants = &.{
            .header = &writer.headerView(std.meta.Child(@FieldType(Constants, "header")), &cells, .Constant),
            .symbols = @ptrCast(&writer.columns.constant_symbols.items),
            .values = @ptrCast(&writer.columns.constant_values.items),
            .bindings = @ptrCast(&bindings),
            .first_symbol = @intCast(symbols.count()),
            .first_expression = @intCast(expressions.count()),
        },
    };

    zx.columns.invoke(rule.executeValue, builder.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    inline for (fields) |name| @field(symbols, name).items.len += count;

    builder.bindings.items.len += count;
    expressions.stores.items.len += count;

    headers.commit(expressions, count);
}
