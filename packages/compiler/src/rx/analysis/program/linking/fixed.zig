const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");
const ExpressionKind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));

pub fn append(builder: *Builder, mapping: *const Mapping, table: *const ir.ExpressionTable, index: usize, borrow_text: bool) Builder.Error!usize {
    const kind = table.kinds[index];
    const row = table.payloads[index];

    return switch (kind) {
        .None, .Unit => 0,
        .Integer => try put(builder, &.{"integers"}, .{table.integers[row]}),
        .NegativeInteger => try put(builder, &.{"negative_integers"}, .{table.negative_integers[row]}),
        .Float => try put(builder, &.{"floats"}, .{table.floats[row]}),
        .String => try put(builder, &.{"strings"}, .{if (borrow_text) table.strings[row] else try builder.allocator.dupe(u8, table.strings[row])}),
        .Boolean => try put(builder, &.{"booleans"}, .{table.booleans[row]}),
        .EnumValue => try put(builder, &.{"enumerations"}, .{table.enumerations[row]}),
        .ErrorValue => try put(builder, &.{"errors"}, .{table.errors[row]}),
        else => visit(kind, Seed{ .builder = builder, .mapping = mapping, .table = table, .row = row }),
    };
}

pub fn visit(kind: ExpressionKind, context: anytype) @TypeOf(context).Output {
    return switch (kind) {
        .Reference => context.mapped(.{ .symbols = &.{"references"} }),
        .Some => context.mapped(.{ .expressions = &.{"some"} }),
        .Capture => context.mapped(.{ .expressions = &.{"captures"} }),
        .OptionalValue => context.mapped(.{ .expressions = &.{"optional_values"} }),
        .Length => context.mapped(.{ .expressions = &.{"lengths"} }),
        .Field, .TupleField => context.mapped(.{
            .expressions = &.{"projection_targets"},
            .raw = &.{"projection_indices"},
        }),
        .Index => context.mapped(.{ .expressions = &.{ "index_targets", "index_values" } }),
        .Unary => context.mapped(.{
            .expressions = &.{"unary_operands"},
            .metadata = &.{"unary_operators"},
        }),
        .Binary => context.mapped(.{
            .expressions = &.{ "binary_left", "binary_right" },
            .metadata = &.{"binary_operators"},
        }),
        .Conditional => context.mapped(.{ .expressions = &.{ "conditional_conditions", "conditional_yes", "conditional_no" } }),
        .ListUpdate => context.mapped(.{ .expressions = &.{ "update_targets", "update_indices", "update_values" } }),
        .Iteration => context.mapped(.{
            .expressions = &.{ "iteration_initials", "iteration_conditions", "iteration_bodies" },
            .symbols = &.{ "iteration_condition_parameters", "iteration_parameters" },
            .optional = "iteration_environment_symbols",
            .metadata = &.{"iteration_postconditions"},
        }),
        else => error.InvalidModule,
    };
}

pub const Payload = struct {
    expressions: []const []const u8 = &.{},
    symbols: []const []const u8 = &.{},
    raw: []const []const u8 = &.{},
    optional: ?[]const u8 = null,
    metadata: []const []const u8 = &.{},
};

const Seed = struct {
    pub const Output = Builder.Error!usize;

    builder: *Builder,
    mapping: *const Mapping,
    table: *const ir.ExpressionTable,
    row: u32,
    pub fn mapped(self: Seed, comptime payload: Payload) Output {
        const builder = self.builder;
        const mapping = self.mapping;
        const table = self.table;
        const row = self.row;
        const fields = comptime payload.expressions ++ payload.symbols ++ payload.raw;
        const optional: []const []const u8 = comptime if (payload.optional) |name| &.{name} else &.{};
        const reserved = comptime fields ++ optional ++ payload.metadata;
        const storage = &builder.expressions;
        const index = @field(storage, fields[0]).items.len;

        try storage.reserveColumns(builder.allocator, reserved, 1);

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

        inline for (fields ++ optional) |name| @field(storage, name).items.len += 1;
        inline for (payload.metadata) |name| @field(storage, name).appendAssumeCapacity(@field(table, name)[row]);

        return index;
    }
};

fn put(builder: *Builder, comptime columns: []const []const u8, values: anytype) Builder.Error!usize {
    const storage = &builder.expressions;
    const index = @field(storage, columns[0]).items.len;

    try storage.reserveColumns(builder.allocator, columns, 1);

    inline for (columns, 0..) |column, field| @field(storage, column).appendAssumeCapacity(values[field]);

    return index;
}
