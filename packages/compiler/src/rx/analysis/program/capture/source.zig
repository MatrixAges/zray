const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Writer = @import("../control/writer.zig");
const Parameters = @import("../capture.zig").Parameters;
const Layout = @import("../../task_captures/layout.zig");
const prefix = @import("generated_rx_capture_prefix");
const argument_rule = @import("generated_rx_capture_argument");
const Prefix = std.meta.Child(prefix.Input);
const ExpressionKind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));
const StatementKind = std.meta.Elem(@FieldType(ir.ControlTable, "statement_kinds"));
const Output = struct { input_type: ir.TypeId, parameters: []const ir.TypeId };

comptime {
    if (@sizeOf(ExpressionKind) != 1 or @sizeOf(StatementKind) != 1 or
        @sizeOf(ir.SymbolId) != @sizeOf(u32) or @sizeOf(ir.TypeId) != @sizeOf(u32))
    {
        @compileError("Capture column buffers require byte tags and u32 IDs");
    }
}

pub fn bind(builder: *Builder, writer: *Writer, cursor: *Writer.Cursor, input_type: ir.TypeId, captures: Parameters, span: zx.Span) std.mem.Allocator.Error!void {
    std.debug.assert(builder.symbols.count() == 0 and builder.expressions.count() == 0 and builder.bindings.items.len == 0);

    const count = captures.positions.len;
    const allocator = builder.allocator;

    errdefer {
        builder.symbols.deinit(allocator);
        builder.expressions.deinit(allocator);
        builder.bindings.deinit(allocator);
    }

    try reserve(builder, count, null);
    try allocate(allocator, builder, &.{"bindings"}, count);

    try write(false, builder, &writer.columns, .{
        .captures = captures,
        .input_type = input_type,
        .span = span,
        .statement = cursor.statement,
        .constant = cursor.counts.constants,
    }, {});

    cursor.statement += @intCast(count);
    cursor.counts.constants += @intCast(count);
}

pub fn argument(allocator: std.mem.Allocator, owner: []const u8, types: ir.TypeTable, environment_type: ir.TypeId, input_type: ir.TypeId, captures: Parameters, layout: Layout, span: zx.Span) std.mem.Allocator.Error!ir.Program {
    const count = captures.positions.len;
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
        .captures = .{ .names = captures.names, .positions = captures.positions, .types = layout.source_types },
        .input_type = environment_type,
        .span = span,
    }, .{ .input_type = input_type, .parameters = captures.types });

    body.* = control.view();

    return .{
        .file_name = owner,
        .types = types,
        .input_type = environment_type,
        .output_type = input_type,
        .symbols = builder.symbols.view(),
        .expressions = builder.expressions.view(),
        .body = .{ .control = body, .root = @fromBackingInt(0) },
    };
}

fn reserve(builder: *Builder, count: usize, optional_count: ?usize) std.mem.Allocator.Error!void {
    const allocator = builder.allocator;
    const expression_count = if (optional_count) |size| (count * 2) + size + 2 else count + 1;

    try allocate(allocator, &builder.symbols, &.{ "names", "types", "span_start", "span_end", "ownership" }, count + 1);

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
    captures: Parameters,
    input_type: ir.TypeId,
    span: zx.Span,
    statement: usize = 0,
    constant: usize = 0,
};

fn write(comptime is_argument: bool, builder: *Builder, control: *ir.ControlStorage, request: Request, output: if (is_argument) Output else void) std.mem.Allocator.Error!void {
    const symbols = &builder.symbols;
    const expressions = &builder.expressions;

    const prefix_input: Prefix = .{
        .symbols = &.{
            .names = @ptrCast(&symbols.names.items),
            .types = @ptrCast(&symbols.types.items),
            .starts = @ptrCast(&symbols.span_start.items),
            .ends = @ptrCast(&symbols.span_end.items),
        },
        .expressions = &.{
            .kinds = @ptrCast(&expressions.kinds.items),
            .payloads = @ptrCast(&expressions.payloads.items),
            .types = @ptrCast(&expressions.types.items),
            .starts = @ptrCast(&expressions.span_start.items),
            .ends = @ptrCast(&expressions.span_end.items),
        },
        .statements = &.{
            .kinds = @ptrCast(&control.statement_kinds.items),
            .payloads = @ptrCast(&control.statement_payloads.items),
            .symbols = @ptrCast(&control.constant_symbols.items),
            .values = @ptrCast(&control.constant_values.items),
        },
        .captures = &.{
            .names = request.captures.names,
            .positions = request.captures.positions,
            .types = @ptrCast(request.captures.types),
        },
        .references = @ptrCast(&expressions.references.items),
        .targets = @ptrCast(&expressions.projection_targets.items),
        .indices = @ptrCast(&expressions.projection_indices.items),
        .bindings = if (is_argument) null else @ptrCast(&builder.bindings.items),
        .span = &.{ .start = request.span.start, .end = request.span.end },
        .input_type = @backingInt(request.input_type),
        .statement = request.statement,
        .constant = request.constant,
        .reference_kind = @backingInt(ExpressionKind.Reference),
        .field_kind = @backingInt(ExpressionKind.TupleField),
        .constant_kind = @backingInt(StatementKind.Constant),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    if (comptime is_argument) {
        const input: std.meta.Child(argument_rule.Input) = .{
            .prefix = &prefix_input,
            .tuple = &.{
                .expressions = prefix_input.expressions,
                .source_types = prefix_input.captures.types,
                .parameter_types = @ptrCast(output.parameters),
                .references = prefix_input.references,
                .optionals = @ptrCast(&expressions.optional_values.items),
                .firsts = @ptrCast(&expressions.sequence_first.items),
                .counts = @ptrCast(&expressions.sequence_count.items),
                .items = @ptrCast(&expressions.sequence_items.items),
                .span = prefix_input.span,
                .result_type = @backingInt(output.input_type),
                .reference_kind = prefix_input.reference_kind,
                .optional_kind = @backingInt(ExpressionKind.OptionalValue),
                .tuple_kind = @backingInt(ExpressionKind.Tuple),
            },
            .result = &.{
                .statements = prefix_input.statements,
                .results = @ptrCast(&control.results.items),
                .block_first = @ptrCast(&control.block_first.items),
                .block_count = @ptrCast(&control.block_count.items),
                .count = request.captures.positions.len,
                .result_kind = @backingInt(StatementKind.Result),
            },
        };

        zx.columns.invoke(argument_rule.executeValue, empty.allocator(), &input) catch unreachable;
    } else {
        zx.columns.invoke(prefix.executeValue, empty.allocator(), &prefix_input) catch unreachable;
    }

    const names = symbols.names.items[1..];
    var owned: usize = 0;

    errdefer for (names[0..owned]) |name| builder.allocator.free(name);

    for (names) |*name| {
        name.* = try builder.allocator.dupe(u8, name.*);
        owned += 1;
    }
}
