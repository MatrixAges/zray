const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Writer = @import("../control/writer.zig");
const Parameters = @import("../capture.zig").Parameters;
const Layout = @import("../../task_captures/layout.zig");
const binding_rule = @import("generated_rx_capture_bind");
const argument_rule = @import("generated_rx_capture_argument");
const ExpressionKind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));
const StatementKind = std.meta.Elem(@FieldType(ir.ControlTable, "statement_kinds"));
const Output = struct { input_type: ir.TypeId, parameters: []const ir.TypeId };

pub fn bind(builder: *Builder, writer: *Writer, cursor: *Writer.Cursor, input_type: ir.TypeId, captures: Parameters, span: zx.Span) std.mem.Allocator.Error!void {
    std.debug.assert(builder.symbols.count() == 0 and builder.expressions.count() == 0 and builder.bindings.items.len == 0);

    const count = captures.positions.len;
    const allocator = builder.allocator;

    errdefer {
        builder.symbols.deinit(allocator);
        builder.expressions.deinit(allocator);
        builder.bindings.deinit(allocator);
    }

    try allocate(allocator, &builder.symbols, &.{"names"}, count + 1);
    try reserve(builder, count, null);
    try allocate(allocator, builder, &.{"bindings"}, count);

    try write(false, builder, &writer.columns, .{
        .types = captures.types,
        .input_type = input_type,
        .span = span,
        .statement = cursor.statement,
        .constant = cursor.counts.constants,
    }, captures);

    cursor.statement += @intCast(count);
    cursor.counts.constants += @intCast(count);
}

pub fn argument(allocator: std.mem.Allocator, owner: []const u8, types: ir.TypeTable, environment_type: ir.TypeId, input_type: ir.TypeId, symbol_names: []const []const u8, layout: Layout, span: zx.Span) std.mem.Allocator.Error!ir.Program {
    const count = layout.positions.len;
    var builder = Builder{ .allocator = allocator, .types = types, .native_modules = .{} };
    var control: ir.ControlStorage = .{};
    const body = try allocator.create(ir.ControlTable);

    errdefer {
        allocator.destroy(body);
        builder.symbols.deinit(allocator);
        builder.expressions.deinit(allocator);
        control.deinit(allocator);
    }

    try reserve(&builder, count, layout.optional_count);
    try allocate(allocator, &control, &.{ "statement_kinds", "statement_payloads" }, count + 1);
    try allocate(allocator, &control, &.{ "constant_symbols", "constant_values" }, count);
    try allocate(allocator, &control, &.{ "block_first", "block_count", "results" }, 1);

    try write(true, &builder, &control, .{
        .types = layout.source_types,
        .input_type = environment_type,
        .span = span,
    }, .{ .input_type = input_type, .parameters = layout.parameter_types });

    body.* = control.view();

    var symbols = builder.symbols.view();

    symbols.names = symbol_names[0 .. count + 1];

    return .{
        .file_name = owner,
        .types = types,
        .input_type = environment_type,
        .output_type = input_type,
        .symbols = symbols,
        .expressions = builder.expressions.view(),
        .body = .{ .control = body, .root = @fromBackingInt(0) },
    };
}

fn reserve(builder: *Builder, count: usize, optional_count: ?usize) std.mem.Allocator.Error!void {
    const allocator = builder.allocator;
    const expression_count = if (optional_count) |size| (count * 2) + size + 2 else count + 1;

    try allocate(allocator, &builder.symbols, &.{ "types", "span_start", "span_end", "ownership" }, count + 1);

    @memset(builder.symbols.ownership.items, .Copy);

    try allocate(allocator, &builder.expressions, &.{ "kinds", "types", "span_start", "span_end", "payloads" }, expression_count);
    try allocate(allocator, &builder.expressions, &.{"references"}, if (optional_count != null) count + 1 else 1);
    try allocate(allocator, &builder.expressions, &.{ "projection_targets", "projection_indices" }, count);

    if (optional_count) |size| {
        try allocate(allocator, &builder.expressions, &.{"optional_values"}, size);
        try allocate(allocator, &builder.expressions, &.{ "sequence_first", "sequence_count" }, 1);
        try allocate(allocator, &builder.expressions, &.{"sequence_items"}, count);
    }
}

fn allocate(allocator: std.mem.Allocator, storage: anytype, comptime fields: []const []const u8, count: usize) std.mem.Allocator.Error!void {
    inline for (fields) |name| {
        const column = &@field(storage, name);
        column.items = try allocator.alloc(std.meta.Elem(@TypeOf(column.items)), count);
        column.capacity = count;
    }
}

const Request = struct {
    types: []const ir.TypeId,
    input_type: ir.TypeId,
    span: zx.Span,
    statement: usize = 0,
    constant: usize = 0,
};

fn copyPrefix(builder: *Builder, control: *ir.ControlStorage, request: Request, prefix: anytype) void {
    const symbols = &builder.symbols;
    const expressions = &builder.expressions;

    for (prefix.symbols, 0..) |row, index| {
        symbols.types.items[index] = row.type_id;
        symbols.span_start.items[index] = row.start;
        symbols.span_end.items[index] = row.end;
    }

    for (prefix.expressions, 0..) |row, index| {
        expressions.kinds.items[index] = @fromBackingInt(@as(@typeInfo(ExpressionKind).@"enum".tag_type, @intCast(row.kind)));
        expressions.payloads.items[index] = row.payload;
        expressions.types.items[index] = row.type_id;
        expressions.span_start.items[index] = row.start;
        expressions.span_end.items[index] = row.end;
    }

    for (prefix.statements, 0..) |row, index| {
        const statement = request.statement + index;
        const constant = request.constant + index;

        control.statement_kinds.items[statement] = @fromBackingInt(@as(@typeInfo(StatementKind).@"enum".tag_type, @intCast(row.kind)));
        control.statement_payloads.items[statement] = row.payload;
        control.constant_symbols.items[constant] = row.symbol;
        control.constant_values.items[constant] = row.value;
    }

    @memcpy(expressions.references.items[0..prefix.references.len], prefix.references);
    @memcpy(expressions.projection_targets.items[0..prefix.targets.len], prefix.targets);
    @memcpy(expressions.projection_indices.items[0..prefix.indices.len], prefix.indices);

    for (prefix.bindings, 0..) |id, index| {
        builder.bindings.items[index] = @fromBackingInt(id);
    }
}

fn write(comptime is_argument: bool, builder: *Builder, control: *ir.ControlStorage, request: Request, output: if (is_argument) Output else Parameters) std.mem.Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(builder.allocator);

    defer arena.deinit();

    var scratch_bytes: [4096]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_bytes, arena.allocator());
    const scratch = fallback.allocator();
    const rule = if (comptime is_argument) argument_rule else binding_rule;
    const Parameter = rule.Input;
    const Input = if (comptime @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const Prefix = std.meta.Child(@FieldType(Input, "prefix"));
    const Span = std.meta.Child(@FieldType(Prefix, "span"));
    const span: Span = .{ .start = request.span.start, .end = request.span.end };

    const prefix_input: Prefix = .{
        .types = @ptrCast(request.types),
        .span = &span,
        .input_type = @backingInt(request.input_type),
        .statement = request.statement,
        .constant = request.constant,
        .reference_kind = @backingInt(ExpressionKind.Reference),
        .field_kind = @backingInt(ExpressionKind.TupleField),
        .constant_kind = @backingInt(StatementKind.Constant),
        .include_bindings = !is_argument,
    };

    if (comptime is_argument) {
        const Tuple = std.meta.Child(@FieldType(Input, "tuple"));
        const Result = std.meta.Child(@FieldType(Input, "result"));

        const tuple_input: Tuple = .{
            .source_types = @ptrCast(request.types),
            .parameter_types = @ptrCast(output.parameters),
            .span = &span,
            .result_type = @backingInt(output.input_type),
            .reference_kind = prefix_input.reference_kind,
            .optional_kind = @backingInt(ExpressionKind.OptionalValue),
            .tuple_kind = @backingInt(ExpressionKind.Tuple),
        };

        const result_input: Result = .{
            .count = request.types.len,
            .result_kind = @backingInt(StatementKind.Result),
        };

        const input: Input = .{
            .prefix = &prefix_input,
            .tuple = &tuple_input,
            .result = &result_input,
        };

        const result = argument_rule.executeValue(scratch, if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        copyPrefix(builder, control, request, result.prefix);

        const expressions = &builder.expressions;
        const base = result.prefix.expressions.len;

        for (result.tuple.expressions, 0..) |row, index| {
            expressions.kinds.items[base + index] = @fromBackingInt(@as(@typeInfo(ExpressionKind).@"enum".tag_type, @intCast(row.kind)));
            expressions.payloads.items[base + index] = row.payload;
            expressions.types.items[base + index] = row.type_id;
            expressions.span_start.items[base + index] = row.start;
            expressions.span_end.items[base + index] = row.end;
        }

        @memcpy(expressions.references.items[1 .. 1 + result.tuple.references.len], result.tuple.references);
        @memcpy(expressions.optional_values.items[0..result.tuple.optionals.len], result.tuple.optionals);
        @memcpy(expressions.sequence_first.items[0..result.tuple.firsts.len], result.tuple.firsts);
        @memcpy(expressions.sequence_count.items[0..result.tuple.counts.len], result.tuple.counts);
        @memcpy(expressions.sequence_items.items[0..result.tuple.items.len], result.tuple.items);

        const count = request.types.len;
        control.statement_kinds.items[count] = @fromBackingInt(@as(@typeInfo(StatementKind).@"enum".tag_type, @intCast(result.result.statement_kind)));
        control.statement_payloads.items[count] = result.result.statement_payload;
        control.results.items[0] = result.result.result_expression;
        control.block_first.items[0] = result.result.block_first;
        control.block_count.items[0] = result.result.block_count;
    } else {
        const Names = std.meta.Child(@FieldType(Input, "names"));

        const names_input: Names = .{
            .source = output.names,
            .positions = output.positions,
        };

        const input: Input = .{
            .prefix = &prefix_input,
            .names = &names_input,
        };

        const result = binding_rule.executeValue(scratch, if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        copyPrefix(builder, control, request, result.prefix);

        var owned: usize = 0;

        errdefer for (builder.symbols.names.items[0..owned]) |name| builder.allocator.free(name);

        for (result.names, 0..) |name, index| {
            builder.symbols.names.items[index] = try builder.allocator.dupe(u8, name);
            owned += 1;
        }
    }
}
