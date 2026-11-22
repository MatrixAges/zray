const Frame = @import("traversal/host.zig").Frame;
const Api = @import("../expressions/evaluate.zig").Api;
const basic = @import("basic.zig");

pub fn beginStatementStore(handle: *const anyopaque, slot: u64, index: u64) ?bool {
    const frame = Frame.borrow(handle);
    frame.prefix = @import("../store/begin.zig").lower(frame.lowering, frame.block(slot), @intCast(index)) catch return null;

    return frame.prefix.len != 0;
}

pub fn joinStatementSpans(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.body = @import("../../node/blocks.zig").join(
        self.allocator,
        self.builder.nodes,
        &.{ frame.prefix.start, frame.body.start },
        &.{ frame.prefix.len, frame.body.len },
    ) catch return false;

    return true;
}

pub fn emitEvaluation(handle: *const anyopaque, slot: u64, index: u64) bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const id = frame.block(slot).at(@intCast(index)).evaluate;
    const value = @import("../iteration.zig").discard(self, id) catch return false;
    const span = basic.discard(self, value) catch return false;

    return frame.emitted(span, false);
}

pub fn emitParallelStatement(handle: *const anyopaque, slot: u64, index: u64) bool {
    const frame = Frame.borrow(handle);
    const invocations = frame.block(slot).at(@intCast(index)).parallel;
    const span = @import("../parallel/root.zig").lower(frame.lowering, invocations) catch return false;

    return frame.emitted(span, false);
}

pub fn emitTaskStatement(handle: *const anyopaque, slot: u64, index: u64) bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const binding = frame.block(slot).at(@intCast(index)).constant;
    const span = @import("../tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol)], binding.value, false) catch return false;

    return frame.emitted(span, false);
}

pub fn statementBinding(handle: *const anyopaque, slot: u64, index: u64) u32 {
    const frame = Frame.borrow(handle);

    frame.sequence.clearRetainingCapacity();

    frame.binding = frame.block(slot).at(@intCast(index)).constant;

    return @backingInt(frame.binding.value);
}

pub fn borrowStatementBinding(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const locals = @import("../value_call/locals.zig");
    const binding = frame.binding;
    frame.borrowed = locals.optionalCall(self, &frame.sequence, binding.symbol, binding.value, self.program.output_type) catch return false;

    return true;
}

pub fn statementBindingUsesValue(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return frame.lowering.stack_symbols.contains(frame.binding.symbol);
}

pub fn borrowedStatementValue(handle: *const anyopaque) ?u32 {
    return if (Frame.borrow(handle).borrowed) |id| @backingInt(id) else null;
}

pub fn lowerStatementExpression(handle: *const anyopaque, value: u32, by_value: bool) ?u32 {
    const self = Frame.borrow(handle).lowering;
    const id = @as(@import("zx").ir.ExprId, @fromBackingInt(value));

    const result = if (by_value)
        @import("../value_call/root.zig").expression(self, id) catch return null

    else
        self.expr(id) catch return null;

    return @backingInt(result);
}

pub fn emitStatementBinding(handle: *const anyopaque, value: u32) bool {
    const frame = Frame.borrow(handle);

    const span = @import("../binding.zig").publish(frame.lowering, &frame.sequence, .{
        .symbol = frame.binding.symbol,
        .value = @fromBackingInt(value),
        .by_value = frame.lowering.stack_symbols.contains(frame.binding.symbol),
    }) catch return false;

    return frame.emitted(span, false);
}

pub fn emitDestructureStatement(handle: *const anyopaque, slot: u64, index: u64) bool {
    const frame = Frame.borrow(handle);
    const binding = frame.block(slot).at(@intCast(index)).destructure;
    const span = @import("destructure/lower.zig").publish(frame.lowering, binding) catch return false;

    return frame.emitted(span, false);
}

pub fn emitStoreWriteStatement(handle: *const anyopaque, slot: u64, index: u64) bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const setter = frame.block(slot).at(@intCast(index)).store_set;
    const target = basic.storeTarget(self, setter.slot) catch return false;
    const value = self.expr(setter.value) catch return false;
    const span = basic.assignment(self, target, value) catch return false;

    return frame.emitted(span, false);
}

pub fn statementResult(handle: *const anyopaque, slot: u64, index: u64) ?u32 {
    const frame = Frame.borrow(handle);
    const source = frame.block(slot).at(@intCast(index)).result;

    frame.sequence.clearRetainingCapacity();

    return if (source) |id| @backingInt(id) else null;
}

pub fn statementResultUsesValue(handle: *const anyopaque) bool {
    return Frame.borrow(handle).lowering.value_output;
}

pub fn statementResultMode(handle: *const anyopaque) Api.StatementResultMode {
    const self = Frame.borrow(handle).lowering;

    if (!self.state_active) return .Plain;

    return if (self.public_value_output) .View else .State;
}

pub fn fuseStatementResult(handle: *const anyopaque, slot: u64, index: u64, value: u32, by_value: bool) bool {
    const frame = Frame.borrow(handle);
    const binding = frame.block(slot).at(@intCast(index - 1)).constant;
    frame.borrowed = @import("../iteration_consumer.zig").lower(frame.lowering, binding.symbol, binding.value, @fromBackingInt(value), by_value) catch return false;

    return true;
}

pub fn clipStatementResult(handle: *const anyopaque, source: u32, value: u32) ?u32 {
    const frame = Frame.borrow(handle);
    const result = @import("../state_value/ownership.zig").clip(frame.lowering, &frame.sequence, @fromBackingInt(source), @fromBackingInt(value)) catch return null;

    return @backingInt(result);
}

pub fn viewStatementResult(handle: *const anyopaque, value: u32) ?u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const boundary = @import("../aggregate.zig").bind(self, &frame.sequence, @fromBackingInt(value)) catch return null;
    const result = @import("../state_value/conversion.zig").convert(self, &frame.sequence, self.program.output_type, boundary, .view_layout) catch return null;

    return @backingInt(result);
}

pub fn emitStatementResult(handle: *const anyopaque, value: ?u32, consumed_previous: bool) bool {
    const frame = Frame.borrow(handle);
    const span = @import("result/lower.zig").emit(frame.lowering, &frame.sequence, if (value) |id| @fromBackingInt(id) else null) catch return false;

    return frame.emitted(span, consumed_previous);
}
