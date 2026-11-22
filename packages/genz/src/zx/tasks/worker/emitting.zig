const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const view = @import("../../../node/view.zig");
const Lower = @import("../../lower.zig");

pub const Parameters = struct { first: u32, count: u32, capture_first: u32 };

pub const Final = struct {
    name: []const u8,
    value: node.ExpressionId,
    output_type: node.ExpressionId,
    errors: ?[]const []const u8,
    parameters_first: u32,
    parameters_count: u32,
    body_first: u32,
    slot: usize,
};

pub fn reserve(self: *Lower, index: usize) Lower.Error![]const u8 {
    const entry = @import("generated_task_worker_reserve");
    const input: std.meta.Child(entry.Input) = .{ .index = index, .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len) };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    try append(self, &self.builder.nodes.expressions, result.expressions);

    const names = try self.task_declarations.appendConstants(self.allocator, result.declarations, false);

    return names[0];
}

pub fn prepare(self: *Lower, captures: []const ir.SymbolId, process: bool) Lower.Error!Parameters {
    const entry = @import("generated_task_worker_prepare");
    const Input = std.meta.Child(entry.Input);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const types = try memory.allocator().alloc(u32, captures.len);

    for (captures, types) |symbol, *type_id| {
        type_id.* = @backingInt(try self.typeExpr(@fromBackingInt(self.program.symbols.types[@backingInt(symbol)])));
    }

    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self);
    const input: Input = .{ .process = process, .symbols = view.slice(@FieldType(Input, "symbols"), captures), .types = types, .bases = &bases };
    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;
    try append(self, &self.builder.nodes.expressions, result.expressions);
    @import("../../../node/import_fields.zig").append(self.allocator, &self.builder.nodes.field_columns, result.fields) catch |err| return failure(err);

    return .{ .first = result.first, .count = result.count, .capture_first = result.capture_first };
}

const name_scope = @import("../../scope/reuse.zig");

pub fn captureNames(lower: *Lower, temporary: std.mem.Allocator, symbols: []const ir.SymbolId, first: u32) Lower.Error!name_scope.Names {
    const saved = try temporary.alloc([]const u8, symbols.len);
    const names = lower.builder.nodes.field_columns.fields.name.values.items;

    return name_scope.bindNames(lower, symbols, names[first..][0..symbols.len], saved);
}

pub fn discard(self: *Lower, worker: *const Lower, captures: []const ir.SymbolId, process: bool) Lower.Error!void {
    const entry = @import("generated_task_worker_discard");
    const Input = std.meta.Child(entry.Input);
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .process = process,
        .uses_allocator = worker.uses_allocator,
        .uses_io = worker.uses_io,
        .uses_process = worker.uses_process,
        .captures = view.slice(@FieldType(Input, "captures"), captures),
        .used = worker.used,
        .names = worker.names,
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;
    try append(self, &self.builder.nodes.expressions, result.expressions);
    try append(self, &self.builder.nodes.statements, result.statements);
}

pub fn finish(self: *Lower, args: Final) Lower.Error!node.ExpressionId {
    const entry = @import("generated_task_worker_finish");
    const Input = std.meta.Child(entry.Input);
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .name = args.name,
        .value = @backingInt(args.value),
        .output_type = @backingInt(args.output_type),
        .errors = args.errors,
        .parameters_first = args.parameters_first,
        .parameters_count = args.parameters_count,
        .body_first = args.body_first,
        .declaration_base = @intCast(self.builder.nodes.declaration_rows.tags.items.len),
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    const expressions = view.join(result.expressions.*, result.extra.*);

    try append(self, &self.builder.nodes.expressions, &expressions);
    try append(self, &self.builder.nodes.statements, result.statements);
    try append(self, &self.builder.nodes.declaration_rows, result.declarations);
    try self.task_declarations.replaceConstant(self.allocator, args.slot, result.alias);

    return @fromBackingInt(result.root);
}

fn context(comptime Bases: type, self: *const Lower) Bases {
    return .{
        .capture = null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };
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
