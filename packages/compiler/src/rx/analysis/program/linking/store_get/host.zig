const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../builder.zig");
const Writer = @import("../../control/writer.zig");
const Binding = @import("../../../store.zig").Binding;
const Columns = @import("../../../store/bindings.zig").Columns;
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
    const Kind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));
    var arena = std.heap.ArenaAllocator.init(builder.allocator);

    defer arena.deinit();

    var scratch_bytes: [4096]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_bytes, arena.allocator());

    const input: Input = .{
        .getters = &getters_view.view(std.meta.Child(@FieldType(Input, "getters"))),
        .span = &.{ .start = span.start, .end = span.end },
        .first_payload = @intCast(expressions.stores.items.len),
        .kind = @backingInt(Kind.StoreGet),
        .copy_tag = @backingInt(ir.SymbolTable.Ownership.Copy),
        .first_symbol = @intCast(symbols.count()),
        .first_expression = @intCast(expressions.count()),
    };

    const result = zx.columns.invoke(rule.executeValue, fallback.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    for (result.symbols) |row| {
        const name = try builder.allocator.dupe(u8, row.name);

        symbols.names.appendAssumeCapacity(name);
        symbols.types.appendAssumeCapacity(row.type_id);
        symbols.span_start.appendAssumeCapacity(row.start);
        symbols.span_end.appendAssumeCapacity(row.end);
        symbols.ownership.appendAssumeCapacity(@fromBackingInt(@as(@typeInfo(ir.SymbolTable.Ownership).@"enum".tag_type, @intCast(row.ownership))));
    }

    for (result.expressions) |row| {
        expressions.kinds.appendAssumeCapacity(@fromBackingInt(@as(@typeInfo(Kind).@"enum".tag_type, @intCast(row.kind))));
        expressions.payloads.appendAssumeCapacity(row.payload);
        expressions.types.appendAssumeCapacity(row.type_id);
        expressions.span_start.appendAssumeCapacity(row.start);
        expressions.span_end.appendAssumeCapacity(row.end);
    }

    expressions.stores.items.len += count;

    for (result.constants) |row| {
        writer.constant(cursor, @fromBackingInt(row.symbol), @fromBackingInt(row.value));
    }

    for (result.bindings) |id| {
        builder.bindings.appendAssumeCapacity(@fromBackingInt(id));
    }
}
