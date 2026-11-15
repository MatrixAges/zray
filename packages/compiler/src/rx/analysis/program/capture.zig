const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Binding = @import("frontend").expressions.Binding;
const Builder = @import("builder.zig");
const Writer = @import("control/writer.zig");
const Counts = @import("control/plan.zig").Counts;
const Layout = @import("../task_captures/layout.zig");
const generated = @import("rx_options").generated_graph;

pub const Parameters = struct {
    names: []const []const u8,
    positions: []const u32,
    types: []const ir.TypeId,
};

pub fn bind(builder: *Builder, writer: *Writer, cursor: *Writer.Cursor, input_type: ir.TypeId, captures: Parameters, span: zx.Span) std.mem.Allocator.Error!void {
    if (comptime generated) return @import("capture/source.zig").bind(builder, writer, cursor, input_type, captures, span);

    const reference = try input(builder, input_type, span);

    for (captures.positions, captures.types, 0..) |position, type_id, index| {
        const capture: Binding = .{ .name = captures.names[position], .type_id = type_id };
        const symbol = try bindOne(builder, writer, cursor, reference, capture, @intCast(index), span);

        try builder.bindings.append(builder.allocator, symbol);
    }
}

pub fn argument(allocator: std.mem.Allocator, owner: []const u8, types: ir.TypeTable, environment_type: ir.TypeId, input_type: ir.TypeId, captures: Parameters, layout: Layout, span: zx.Span) std.mem.Allocator.Error!ir.Program {
    if (comptime generated) return @import("capture/source.zig").argument(allocator, owner, types, environment_type, input_type, captures, layout, span);

    var builder = Builder{ .allocator = allocator, .types = types, .native_modules = .{} };
    const count = std.math.cast(u32, captures.types.len) orelse return error.OutOfMemory;
    const size = Counts{ .constants = count, .results = 1 };

    if (size.statements() > std.math.maxInt(u32)) return error.OutOfMemory;

    var writer = try Writer.init(allocator, 1);
    var cursor = Writer.Cursor.init(.{});

    errdefer writer.columns.deinit(allocator);

    try writer.reserve(allocator, size);

    writer.columns.block_first.items[0] = 0;
    writer.columns.block_count.items[0] = @intCast(size.statements());

    const environment = try input(&builder, environment_type, span);

    for (captures.positions, layout.source_types, 0..) |position, type_id, index| {
        const binding: Binding = .{ .name = captures.names[position], .type_id = type_id };

        _ = try bindOne(&builder, &writer, &cursor, environment, binding, @intCast(index), span);
    }

    for (captures.types, layout.source_types, layout.elements, 1..) |parameter_type, type_id, element, symbol| {
        const reference = try builder.expression(.{ .type_id = type_id, .span = span, .value = .{ .reference = @fromBackingInt(@intCast(symbol)) } });

        if (reference != element) {
            const payload = try builder.expression(.{ .type_id = parameter_type, .span = span, .value = .{ .optional_value = reference } });

            std.debug.assert(payload == element);
        }
    }

    const result = try builder.expression(.{ .type_id = input_type, .span = span, .value = .{ .tuple = layout.elements } });

    writer.result(&cursor, result);

    const root = writer.finishBlock(&cursor, 0, &size) catch unreachable;

    return .{ .file_name = owner, .types = types, .input_type = environment_type, .output_type = input_type, .symbols = builder.symbols.view(), .expressions = builder.expressions.view(), .body = try writer.columns.finish(allocator, root) };
}

fn input(builder: *Builder, type_id: ir.TypeId, span: zx.Span) std.mem.Allocator.Error!ir.ExprId {
    const symbol = try builder.symbol("@environment", type_id, span);

    return builder.expression(.{ .type_id = type_id, .span = span, .value = .{ .reference = symbol } });
}

fn bindOne(builder: *Builder, writer: *Writer, cursor: *Writer.Cursor, reference: ir.ExprId, capture: Binding, index: u32, span: zx.Span) std.mem.Allocator.Error!ir.SymbolId {
    const symbol = try builder.symbol(capture.name, capture.type_id, span);
    const value = try builder.expression(.{ .type_id = capture.type_id, .span = span, .value = .{ .tuple_field = .{ .target = reference, .index = index } } });

    writer.constant(cursor, symbol, value);

    return symbol;
}
