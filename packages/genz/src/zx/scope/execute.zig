const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Lower = @import("../lower.zig");
const Iteration = @import("../iteration_value/root.zig");
const reuse = @import("reuse.zig");
const evaluation = @import("../expressions/evaluate.zig");
const entry = @import("generated_lower_scope_bindings");
const Error = Lower.Error;
const packSpan = @import("../construction/publication.zig").packSpan;
const inline_span_count = 32;
const inline_preparation_words = 4;

fn run(lowering: *Lower, temporary: std.mem.Allocator, scope: ir.ScopeRow, layout: bool, aliases: ?*const reuse, comptime iteration_mode: bool) Error!node.ExpressionId {
    const Input = std.meta.Child(entry.Input);
    const Selection = std.meta.Child(@FieldType(Input, "selection"));
    const expressions = &lowering.program.expressions;
    const stack = lowering.stack_symbols.current();

    const selection: Selection = .{
        .symbols = scope.bindings.symbols,
        .values = scope.bindings.values,
        .kinds = zx.columns.slice(@FieldType(Selection, "kinds"), expressions.kinds),
        .types = expressions.types,
        .type_kinds = lowering.program.types.kinds,
        .used = lowering.used,
        .stack_keys = @ptrCast(&stack.keys.items),
        .stack_buckets = @ptrCast(&stack.buckets.items),
        .changes = if (aliases) |active| active.state.changes else &.{},
        .iteration = iteration_mode,
    };

    var sequence = lowering.builder.statementSequence(lowering.workspace);

    defer sequence.deinit();

    var origin: @import("../construction/publication.zig").OriginBuffer = undefined;

    const input: Input = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .sequence = @ptrCast(&sequence),
        .origin = @ptrCast(&origin),
        .result = @backingInt(scope.result),
        .layout = layout,
        .selection = &selection,
        .candidates = if (aliases) |active| zx.columns.pointer(std.meta.Child(@FieldType(Input, "candidates")), active.state.candidates) else null,
        .variables = if (aliases) |active| active.variables else &.{},
        .names = lowering.names,
        .symbol_types = if (iteration_mode) lowering.program.symbols.types else &.{},
    };

    const output = entry.executeIn(temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(output);
}

pub fn regular(lowering: *Lower, temporary: std.mem.Allocator, scope: ir.ScopeRow, layout: bool, aliases: ?*const reuse) Error!node.ExpressionId {
    var inline_spans: [inline_span_count + inline_preparation_words]u64 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&inline_spans), temporary);

    return run(lowering, memory.allocator(), scope, layout, aliases, false);
}

pub fn iteration(context: *Iteration, allocator: std.mem.Allocator, scope: ir.ScopeRow) Error!node.ExpressionId {
    return run(context.lowering, allocator, scope, false, null, true);
}

pub fn consumeScopeResult(handle: *anyopaque, symbol: u32, value: u32, result: u32, layout: bool) Error!?u32 {
    const lowering = evaluation.borrow(handle);
    const consumed = try @import("../iteration_consumer.zig").lower(lowering, @fromBackingInt(symbol), @fromBackingInt(value), @fromBackingInt(result), layout);

    return if (consumed) |id| @backingInt(id) else null;
}

pub fn reuseScopeBinding(handle: *anyopaque, previous: u32, reference: u32, type_id: u32, field_index: u32, field_value: u32) Error!u64 {
    const lowering = evaluation.borrow(handle);

    const block = try @import("../object_update/emit.zig").statementBlock(lowering, .{
        .previous = @fromBackingInt(previous),
        .reference = @fromBackingInt(reference),
        .field = .{ .index = field_index, .value = @fromBackingInt(field_value) },
        .type_id = @fromBackingInt(type_id),
    });

    return packSpan(block);
}

pub fn prepareScopeBinding(writer: *anyopaque, sequence: *anyopaque, symbol: ?u32, value: u32, type_id: u32) Error!?u32 {
    const lowering = evaluation.borrow(writer);
    const body: *Sequence = @ptrCast(@alignCast(sequence));
    const key = symbol orelse return null;
    const borrowed = try @import("../value_call/locals.zig").optionalCall(lowering, body, @fromBackingInt(key), @fromBackingInt(value), @fromBackingInt(type_id));

    return if (borrowed) |id| @backingInt(id) else null;
}

pub fn publishScopeBinding(writer: *anyopaque, sequence: *anyopaque, symbol: ?u32, value: u32, layout: bool, mutable: bool) Error!u64 {
    const lowering = evaluation.borrow(writer);
    const body: *Sequence = @ptrCast(@alignCast(sequence));

    const block = try @import("../binding.zig").publish(lowering, body, .{
        .symbol = if (symbol) |id| @fromBackingInt(id) else null,
        .value = @fromBackingInt(value),
        .by_value = layout,
        .scope = true,
        .mutable = mutable,
    });

    body.deinit();

    body.* = lowering.builder.statementSequence(lowering.workspace);

    return packSpan(block);
}
