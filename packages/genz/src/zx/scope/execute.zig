const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const Iteration = @import("../iteration_value/root.zig");
const reuse = @import("reuse.zig");
const evaluation = @import("../expressions/evaluate.zig");
const entry = @import("generated_lower_scope_bindings");
const Error = Lower.Error;
const packSpan = @import("../construction/publication.zig").packSpan;
const inline_span_count = 32;
const inline_preparation_words = 4;

const Frame = struct {
    lowering: *Lower,
    scope: ir.ScopeRow,
    temporary: std.mem.Allocator,
    aliases: ?*const reuse = null,
    sequence: ?blocks.Sequence = null,
    fn run(self: *Frame, layout: bool, comptime iteration_mode: bool) Error!node.ExpressionId {
        const Input = std.meta.Child(entry.Input);
        const Selection = std.meta.Child(@FieldType(Input, "selection"));
        const ValueColumns = std.meta.Child(@FieldType(Input, "values"));
        const lowering = self.lowering;
        const expressions = &lowering.program.expressions;
        const stack = lowering.stack_symbols.current();
        var spans: []u64 = &.{};
        var lowered: []?u32 = &.{};
        var types: []?u32 = &.{};
        var names: [][]const u8 = &.{};
        const values: ValueColumns = .{ .values = @ptrCast(&lowered), .types = @ptrCast(&types), .names = @ptrCast(&names) };

        const selection: Selection = .{
            .symbols = self.scope.bindings.symbols,
            .values = self.scope.bindings.values,
            .kinds = zx.columns.slice(@FieldType(Selection, "kinds"), expressions.kinds),
            .types = expressions.types,
            .type_kinds = lowering.program.types.kinds,
            .used = lowering.used,
            .stack_keys = @ptrCast(&stack.keys.items),
            .stack_buckets = @ptrCast(&stack.buckets.items),
            .changes = if (self.aliases) |active| active.state.changes else &.{},
            .iteration = iteration_mode,
        };

        var origin: @import("../construction/publication.zig").OriginBuffer = undefined;

        const input: Input = .{
            .frame = @ptrCast(lowering),
            .scope = @ptrCast(&self),
            .writer = @ptrCast(lowering),
            .origin = @ptrCast(&origin),
            .result = @backingInt(self.scope.result),
            .layout = layout,
            .selection = &selection,
            .spans = @ptrCast(&spans),
            .values = &values,
            .names = lowering.names,
            .symbol_types = if (iteration_mode) lowering.program.symbols.types else &.{},
        };

        const output = entry.executeIn(self.temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

        return @fromBackingInt(output);
    }
};

pub fn regular(lowering: *Lower, temporary: std.mem.Allocator, scope: ir.ScopeRow, layout: bool, aliases: ?*const reuse) Error!node.ExpressionId {
    var inline_spans: [inline_span_count + inline_preparation_words]u64 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&inline_spans), temporary);
    var frame: Frame = .{ .lowering = lowering, .scope = scope, .temporary = memory.allocator(), .aliases = aliases };

    defer if (frame.sequence) |*sequence| sequence.deinit();

    return frame.run(layout, false);
}

pub fn iteration(context: *Iteration, allocator: std.mem.Allocator, scope: ir.ScopeRow) Error!node.ExpressionId {
    var frame: Frame = .{ .lowering = context.lowering, .scope = scope, .temporary = allocator };

    return frame.run(false, true);
}

fn borrow(handle: *const anyopaque) *Frame {
    const reference: *const *Frame = @ptrCast(@alignCast(handle));

    return reference.*;
}

pub fn consumeScopeResult(handle: *const anyopaque, symbol: u32, value: u32, layout: bool) Error!?u32 {
    const frame = borrow(handle);
    const result = try @import("../iteration_consumer.zig").lower(frame.lowering, @fromBackingInt(symbol), @fromBackingInt(value), frame.scope.result, layout);

    return if (result) |id| @backingInt(id) else null;
}

pub fn reuseScopeBinding(handle: *const anyopaque, position: u64) Error!u64 {
    const frame = borrow(handle);
    const block = (try frame.aliases.?.publish(frame.lowering, @intCast(position))).?;

    return packSpan(block);
}

pub fn prepareScopeBinding(handle: *const anyopaque, symbol: ?u32, value: u32, type_id: u32) Error!?u32 {
    const frame = borrow(handle);
    const self = frame.lowering;

    frame.sequence = self.builder.statementSequence(self.workspace);

    const key = symbol orelse return null;
    const borrowed = try @import("../value_call/locals.zig").optionalCall(self, &frame.sequence.?, @fromBackingInt(key), @fromBackingInt(value), @fromBackingInt(type_id));

    return if (borrowed) |id| @backingInt(id) else null;
}

pub fn publishScopeBinding(handle: *const anyopaque, position: u64, symbol: ?u32, value: u32, layout: bool) Error!u64 {
    const frame = borrow(handle);
    const mutable = if (frame.aliases) |active| active.variables[@intCast(position)] else false;

    const block = try @import("../binding.zig").publish(frame.lowering, &frame.sequence.?, .{
        .symbol = if (symbol) |id| @fromBackingInt(id) else null,
        .value = @fromBackingInt(value),
        .by_value = layout,
        .scope = true,
        .mutable = mutable,
    });

    frame.sequence.?.deinit();

    frame.sequence = null;

    return packSpan(block);
}

pub fn completeIterationScope(handle: *const anyopaque, bindings: *const evaluation.Api.IterationScopeBindings, result: u32) Error!u32 {
    const frame = borrow(handle);

    return @backingInt(try @import("../iteration_value/scope.zig").emit(frame.lowering, frame.temporary, @fromBackingInt(result), bindings));
}
