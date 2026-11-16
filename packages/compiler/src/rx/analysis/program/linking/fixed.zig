const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");
const operands = @import("operands.zig");
const generated = @import("rx_options").generated_graph;
const ExpressionKind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));

pub fn append(builder: *Builder, mapping: *const Mapping, table: *const ir.ExpressionTable, index: usize, borrow_text: bool) Builder.Error!usize {
    const kind = table.kinds[index];
    const row = table.payloads[index];

    return switch (kind) {
        .None, .Unit => 0,
        .Integer => if (comptime generated) unreachable else try put(builder, &.{"integers"}, .{table.integers[row]}),
        .NegativeInteger => if (comptime generated) unreachable else try put(builder, &.{"negative_integers"}, .{table.negative_integers[row]}),
        .Float => if (comptime generated) unreachable else try put(builder, &.{"floats"}, .{table.floats[row]}),
        .String => if (comptime generated) unreachable else try put(builder, &.{"strings"}, .{if (borrow_text) table.strings[row] else try builder.allocator.dupe(u8, table.strings[row])}),
        .Boolean => if (comptime generated) unreachable else try put(builder, &.{"booleans"}, .{table.booleans[row]}),
        .EnumValue => if (comptime generated) unreachable else try put(builder, &.{"enumerations"}, .{table.enumerations[row]}),
        .ErrorValue => if (comptime generated) unreachable else try put(builder, &.{"errors"}, .{table.errors[row]}),
        .Reference => try mapped(builder, mapping, table, kind, row, .{ .symbols = &.{"references"} }),
        .Some => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{"some"} }),
        .Capture => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{"captures"} }),
        .OptionalValue => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{"optional_values"} }),
        .Length => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{"lengths"} }),
        .Field, .TupleField => try mapped(builder, mapping, table, kind, row, .{
            .expressions = &.{"projection_targets"},
            .raw = &.{"projection_indices"},
        }),
        .Index => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{ "index_targets", "index_values" } }),
        .Unary => try mapped(builder, mapping, table, kind, row, .{
            .expressions = &.{"unary_operands"},
            .metadata = &.{"unary_operators"},
        }),
        .Binary => try mapped(builder, mapping, table, kind, row, .{
            .expressions = &.{ "binary_left", "binary_right" },
            .metadata = &.{"binary_operators"},
        }),
        .Conditional => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{ "conditional_conditions", "conditional_yes", "conditional_no" } }),
        .ListUpdate => try mapped(builder, mapping, table, kind, row, .{ .expressions = &.{ "update_targets", "update_indices", "update_values" } }),
        .Iteration => try mapped(builder, mapping, table, kind, row, .{
            .expressions = &.{ "iteration_initials", "iteration_conditions", "iteration_bodies" },
            .symbols = &.{ "iteration_condition_parameters", "iteration_parameters" },
            .optional = "iteration_environment_symbols",
            .metadata = &.{"iteration_postconditions"},
        }),
        else => return error.InvalidModule,
    };
}

const Payload = struct {
    expressions: []const []const u8 = &.{},
    symbols: []const []const u8 = &.{},
    raw: []const []const u8 = &.{},
    optional: ?[]const u8 = null,
    metadata: []const []const u8 = &.{},
};

fn mapped(builder: *Builder, mapping: *const Mapping, table: *const ir.ExpressionTable, kind: ExpressionKind, row: u32, comptime payload: Payload) Builder.Error!usize {
    const fields = comptime payload.expressions ++ payload.symbols ++ payload.raw;
    const optional: []const []const u8 = comptime if (payload.optional) |name| &.{name} else &.{};
    const reserved = comptime fields ++ optional ++ payload.metadata;
    const storage = &builder.expressions;
    const index = @field(storage, fields[0]).items.len;

    try storage.reserveColumns(builder.allocator, reserved, 1);

    if (comptime generated) {
        const rule = @import("generated_rx_link_fixed_operands");
        const Input = std.meta.Child(rule.Input);
        const Symbols = std.meta.Child(@FieldType(Input, "symbols"));
        const Kind = @FieldType(Input, "kind");
        const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "columns")));
        var views: [fields.len][]u32 = undefined;
        var columns: [fields.len]Column = undefined;
        var pointers: [fields.len]*const Column = undefined;
        const environment: []?u32 = if (comptime payload.optional) |name| @field(storage, name).unusedCapacitySlice()[0..1] else &.{};

        inline for (fields, 0..) |name, column| {
            views[column] = @field(storage, name).unusedCapacitySlice()[0..1];
            columns[column] = .{ .source = @field(table, name), .target = @ptrCast(&views[column]) };
            pointers[column] = &columns[column];
        }

        const input: Input = .{
            .kind = @as(Kind, @fromBackingInt(@intCast(@backingInt(kind)))),
            .columns = &pointers,
            .row = row,
            .mapping = mapping.expressions[0..mapping.available],
            .symbols = &operands.symbolView(Symbols, mapping),
            .optional_symbol = if (comptime payload.optional) |name| @field(table, name)[row] else null,
            .optional_target = if (comptime payload.optional != null) @ptrCast(&environment) else null,
        };

        if (!try operands.invoke(rule, input)) return error.InvalidModule;
    } else {
        inline for (payload.expressions) |name| {
            const id = try mapping.seedId(@fromBackingInt(@field(table, name)[row]));

            @field(storage, name).unusedCapacitySlice()[0] = @backingInt(id);
        }

        inline for (payload.symbols) |name| {
            const id = try mapping.seedSymbol(@fromBackingInt(@field(table, name)[row]));

            @field(storage, name).unusedCapacitySlice()[0] = @backingInt(id);
        }

        inline for (payload.raw) |name| @field(storage, name).unusedCapacitySlice()[0] = @field(table, name)[row];

        if (comptime payload.optional) |name| {
            const id = @field(table, name)[row];

            @field(storage, name).unusedCapacitySlice()[0] = if (id) |value| @backingInt(try mapping.seedSymbol(@fromBackingInt(value))) else null;
        }
    }

    inline for (fields ++ optional) |name| @field(storage, name).items.len += 1;
    inline for (payload.metadata) |name| @field(storage, name).appendAssumeCapacity(@field(table, name)[row]);

    return index;
}

fn put(builder: *Builder, comptime columns: []const []const u8, values: anytype) Builder.Error!usize {
    const storage = &builder.expressions;
    const index = @field(storage, columns[0]).items.len;

    try storage.reserveColumns(builder.allocator, columns, 1);

    inline for (columns, 0..) |column, field| @field(storage, column).appendAssumeCapacity(values[field]);

    return index;
}
