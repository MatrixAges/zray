const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const view = @import("../../../node/view.zig");
const Lower = @import("../../lower.zig");
const blocks = @import("../../../node/blocks.zig");

pub const Prepared = struct { names: [3][]const u8, raw: [2]node.ExpressionId };

pub const Final = struct {
    worker: *const Lower,
    environment: ir.SymbolId,
    child: node.ExpressionId,
    output_type: node.ExpressionId,
    errors: ?[]const []const u8,
    value: node.ExpressionId,
    raw: [2]node.ExpressionId,
    elements: [2]node.ExpressionId,
    used: [2]bool,
    helpers: [2][]const node.Statement,
};

pub fn prepare(self: *Lower) Lower.Error!Prepared {
    const entry = @import("generated_sorting_worker_prepare");
    const input: std.meta.Child(entry.Input) = .{ .base = @intCast(self.builder.nodes.expressions.tags.items.len) };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    try append(self, &self.builder.nodes.expressions, result.expressions);

    return .{
        .names = .{ result.left_name, result.right_name, result.environment_name },
        .raw = .{ @fromBackingInt(result.left), @fromBackingInt(result.right) },
    };
}

pub fn finish(self: *Lower, args: Final) Lower.Error!node.Declaration {
    const entry = @import("generated_sorting_worker");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const references = try args.worker.referenceBlock();

    const bases: Bases = .{
        .capture = null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const raw: []const node.ExpressionId = &args.raw;
    const elements: []const node.ExpressionId = &args.elements;

    const input: Input = .{
        .child = @backingInt(args.child),
        .output_type = @backingInt(args.output_type),
        .errors = args.errors,
        .value = @backingInt(args.value),
        .raw = view.slice(@FieldType(Input, "raw"), raw),
        .elements = view.slice(@FieldType(Input, "elements"), elements),
        .used = &args.used,
        .uses_allocator = args.worker.uses_allocator,
        .uses_io = args.worker.uses_io,
        .uses_process = args.worker.uses_process,
        .uses_environment = args.worker.used[@backingInt(args.environment)],
        .reference_count = references.len,
        .helper_count = args.helpers[0].len + args.helpers[1].len,
        .bases = &bases,
        .declaration_base = @intCast(self.builder.nodes.declaration_rows.tags.items.len),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    const expressions = view.join(view.join(result.expressions.*, result.forms.*), result.extra.*);

    try append(self, &self.builder.nodes.expressions, &expressions);

    _ = @import("../../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, result.fields) catch |err| return failure(err);

    const prefix = try self.builder.publishStatements(&.{}, result.prefix);
    const left = try self.builder.statements(args.helpers[0]);
    const bindings = try self.builder.publishStatements(&.{}, result.bindings);
    const right = try self.builder.statements(args.helpers[1]);
    const ending = try self.builder.publishStatements(&.{}, result.ending);

    const body = try blocks.join(
        self.allocator,
        self.builder.nodes,
        &.{ prefix.start, references.start, left.start, bindings.start, right.start, bindings.start + 1, ending.start },
        &.{ prefix.len, references.len, left.len, 1, right.len, 1, ending.len },
    );

    var declarations = result.declarations.*;

    declarations.function_body_start = &.{body.start};

    try append(self, &self.builder.nodes.declaration_rows, &declarations);

    return .{ .function = try self.builder.nodes.materializeFunction(self.allocator, input.declaration_base) };
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../../node/import_rows.zig").appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
