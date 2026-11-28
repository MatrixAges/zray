const Lower = @import("../lower.zig");
const Frame = @import("traversal/host.zig").Frame;
const rows = @import("../construction/publication.zig");

pub fn beginStatementStore(handle: *const anyopaque, slot: u64, index: u64) ?u64 {
    const frame = Frame.borrow(handle);
    const span = @import("../store/begin.zig").lower(frame.lowering, frame.block(slot), @intCast(index)) catch return null;

    return rows.packSpan(span);
}

pub fn emitParallelStatement(handle: *const anyopaque, slot: u64, index: u64) ?u64 {
    const frame = Frame.borrow(handle);
    const invocations = frame.block(slot).at(@intCast(index)).parallel;
    const span = @import("../parallel/root.zig").lower(frame.lowering, invocations) catch return null;

    return rows.packSpan(span);
}

pub fn borrowStatementBinding(handle: *const anyopaque, symbol: u32, value: u32) Lower.Error!?u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const locals = @import("../value_call/locals.zig");

    frame.sequence.clearRetainingCapacity();

    const borrowed = try locals.optionalCall(self, &frame.sequence, @fromBackingInt(symbol), @fromBackingInt(value), self.program.output_type);

    return if (borrowed) |id| @backingInt(id) else null;
}

pub fn emitStatementBinding(handle: *const anyopaque, raw_symbol: u32, value: u32) ?u64 {
    const frame = Frame.borrow(handle);
    const symbol: @import("zx").ir.SymbolId = @fromBackingInt(raw_symbol);

    const span = @import("../binding.zig").publish(frame.lowering, &frame.sequence, .{
        .symbol = symbol,
        .value = @fromBackingInt(value),
        .by_value = frame.lowering.stack_symbols.contains(symbol),
    }) catch return null;

    return rows.packSpan(span);
}

pub fn statementResult(handle: *const anyopaque, slot: u64, index: u64) ?u32 {
    const frame = Frame.borrow(handle);
    const source = frame.block(slot).at(@intCast(index)).result;

    frame.sequence.clearRetainingCapacity();

    return if (source) |id| @backingInt(id) else null;
}

pub fn fuseStatementResult(handle: *const anyopaque, slot: u64, index: u64, value: u32, by_value: bool) Lower.Error!?u32 {
    const frame = Frame.borrow(handle);
    const binding = frame.block(slot).at(@intCast(index - 1)).constant;
    const fused = try @import("../iteration_consumer.zig").lower(frame.lowering, binding.symbol, binding.value, @fromBackingInt(value), by_value);

    return if (fused) |id| @backingInt(id) else null;
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
