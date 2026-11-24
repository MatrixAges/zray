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
const Spans = struct { starts: []u32, counts: []u32 };
const Values = struct { values: []?u32, types: []?u32, names: [][]const u8 };

const Regular = struct {
    aliases: *const ?reuse,
    inline_spans: [64]u32 = undefined,
    allocated: ?[]u32 = null,
    spans: Spans = undefined,
    sequence: ?blocks.Sequence = null,
};

const Iterated = struct {
    allocator: std.mem.Allocator,
    values: Values = undefined,
};

const Frame = struct {
    lowering: *Lower,
    scope: ir.ScopeRow,
    state: union(enum) { regular: Regular, iteration: Iterated },
    span: [2]u32 = undefined,
    fn run(self: *Frame, layout: bool) Error!node.ExpressionId {
        const Input = std.meta.Child(entry.Input);
        const Selection = std.meta.Child(@FieldType(Input, "selection"));
        const SpanColumns = std.meta.Child(std.meta.Child(@FieldType(Input, "spans")));
        const ValueColumns = std.meta.Child(std.meta.Child(@FieldType(Input, "values")));
        const lowering = self.lowering;
        const iteration_mode = self.state == .iteration;
        const expressions = &lowering.program.expressions;
        const stack = lowering.stack_symbols.current();
        const current: []u32 = &self.span;

        const spans: SpanColumns = if (!iteration_mode) .{
            .starts = @ptrCast(&self.state.regular.spans.starts),
            .counts = @ptrCast(&self.state.regular.spans.counts),
            .current = @ptrCast(&current),
        } else undefined;

        const values: ValueColumns = if (iteration_mode) .{
            .values = @ptrCast(&self.state.iteration.values.values),
            .types = @ptrCast(&self.state.iteration.values.types),
            .names = @ptrCast(&self.state.iteration.values.names),
        } else undefined;

        const selection: Selection = .{
            .symbols = self.scope.bindings.symbols,
            .values = self.scope.bindings.values,
            .kinds = zx.columns.slice(@FieldType(Selection, "kinds"), expressions.kinds),
            .types = expressions.types,
            .type_kinds = lowering.program.types.kinds,
            .used = lowering.used,
            .stack_keys = @ptrCast(&stack.keys.items),
            .stack_buckets = @ptrCast(&stack.buckets.items),
            .changes = if (!iteration_mode and self.state.regular.aliases.* != null) self.state.regular.aliases.*.?.state.changes else &.{},
            .iteration = iteration_mode,
        };

        const input: Input = .{
            .frame = @ptrCast(lowering),
            .scope = @ptrCast(self),
            .result = @backingInt(self.scope.result),
            .layout = layout,
            .selection = &selection,
            .spans = if (iteration_mode) null else &spans,
            .values = if (iteration_mode) &values else null,
            .names = if (iteration_mode) lowering.names else &.{},
            .symbol_types = if (iteration_mode) lowering.program.symbols.types else &.{},
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        const output = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        return @fromBackingInt(output.value);
    }
};

pub fn regular(lowering: *Lower, scope: ir.ScopeRow, layout: bool, aliases: *const ?reuse) Error!node.ExpressionId {
    var frame: Frame = .{ .lowering = lowering, .scope = scope, .state = .{ .regular = .{ .aliases = aliases } } };
    const ordinary = &frame.state.regular;

    defer if (ordinary.allocated) |allocation| lowering.workspace.free(allocation);
    defer if (ordinary.sequence) |*sequence| sequence.deinit();

    return frame.run(layout);
}

pub fn iteration(context: *Iteration, allocator: std.mem.Allocator, scope: ir.ScopeRow) Error!node.ExpressionId {
    var frame: Frame = .{ .lowering = context.lowering, .scope = scope, .state = .{ .iteration = .{ .allocator = allocator } } };

    return frame.run(false);
}

fn borrow(handle: *const anyopaque) *Frame {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn consumeScopeResult(handle: *const anyopaque, symbol: u32, value: u32, layout: bool) Error!?u32 {
    const frame = borrow(handle);
    const result = try @import("../iteration_consumer.zig").lower(frame.lowering, @fromBackingInt(symbol), @fromBackingInt(value), frame.scope.result, layout);

    return if (result) |id| @backingInt(id) else null;
}

pub fn beginScopeBindings(handle: *const anyopaque, length: u64) Error!void {
    const frame = borrow(handle);
    const count: usize = @intCast(length);

    switch (frame.state) {
        .regular => |*state| {
            const total = std.math.mul(usize, count, 2) catch return error.OutOfMemory;

            const spans = if (total <= state.inline_spans.len) state.inline_spans[0..total] else allocated: {
                const allocation = try frame.lowering.workspace.alloc(u32, total);
                state.allocated = allocation;

                break :allocated allocation;
            };

            state.spans = .{ .starts = spans[0..count], .counts = spans[count..] };
        },
        .iteration => |*state| {
            state.values = .{
                .values = try state.allocator.alloc(?u32, count),
                .types = try state.allocator.alloc(?u32, count),
                .names = try state.allocator.alloc([]const u8, count),
            };
        },
    }
}

pub fn reuseScopeBinding(handle: *const anyopaque, position: u64) Error!void {
    const frame = borrow(handle);
    const block = (try frame.state.regular.aliases.*.?.publish(frame.lowering, @intCast(position))).?;

    frame.span = .{ block.start, block.len };
}

pub fn emitScopeTask(handle: *const anyopaque, symbol: ?u32, value: u32) Error!void {
    const frame = borrow(handle);
    const block = try @import("../tasks/root.zig").bind(frame.lowering, frame.lowering.names[symbol.?], @fromBackingInt(value), false);

    frame.span = .{ block.start, block.len };
}

pub fn prepareScopeBinding(handle: *const anyopaque, symbol: ?u32, value: u32, type_id: u32) Error!?u32 {
    const frame = borrow(handle);
    const self = frame.lowering;
    const ordinary = &frame.state.regular;

    ordinary.sequence = self.builder.statementSequence(self.workspace);

    const key = symbol orelse return null;
    const borrowed = try @import("../value_call/locals.zig").optionalCall(self, &ordinary.sequence.?, @fromBackingInt(key), @fromBackingInt(value), @fromBackingInt(type_id));

    return if (borrowed) |id| @backingInt(id) else null;
}

pub fn discardScopeOperand(handle: *const anyopaque, operand: u32) Error!u32 {
    return @backingInt(try @import("../iteration.zig").discard(evaluation.borrow(handle), @fromBackingInt(operand)));
}

pub fn publishScopeBinding(handle: *const anyopaque, position: u64, symbol: ?u32, value: u32, layout: bool) Error!void {
    const frame = borrow(handle);
    const ordinary = &frame.state.regular;
    const mutable = if (ordinary.aliases.*) |active| active.variables[@intCast(position)] else false;

    const block = try @import("../binding.zig").publish(frame.lowering, &ordinary.sequence.?, .{
        .symbol = if (symbol) |id| @fromBackingInt(id) else null,
        .value = @fromBackingInt(value),
        .by_value = layout,
        .scope = true,
        .mutable = mutable,
    });

    ordinary.sequence.?.deinit();

    ordinary.sequence = null;
    frame.span = .{ block.start, block.len };
}

pub fn finishScopeBindings(handle: *const anyopaque, result: u32) Error!u32 {
    const frame = borrow(handle);
    const lowering = frame.lowering;
    const value: node.ExpressionId = @fromBackingInt(result);

    return @backingInt(switch (frame.state) {
        .regular => |state| lowered: {
            const body = try blocks.tail(lowering.allocator, lowering.builder.nodes, state.spans.starts, state.spans.counts);

            break :lowered try @import("../aggregate.zig").finishStored(lowering, body, value, null);
        },
        .iteration => |state| try @import("../iteration_value/scope.zig").emit(lowering, state.allocator, value, &.{
            .symbols = frame.scope.bindings.symbols,
            .values = state.values.values,
            .types = state.values.types,
            .names = state.values.names,
        }),
    });
}
