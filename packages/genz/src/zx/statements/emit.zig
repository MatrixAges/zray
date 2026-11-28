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

pub fn emitStatementBinding(handle: *const anyopaque, raw_symbol: u32, value: u32) ?u64 {
    const frame = Frame.borrow(handle);
    const symbol: @import("zx").ir.SymbolId = @fromBackingInt(raw_symbol);

    defer frame.sequence.clearRetainingCapacity();

    const span = @import("../binding.zig").publish(frame.lowering, &frame.sequence, .{
        .symbol = symbol,
        .value = @fromBackingInt(value),
        .by_value = frame.lowering.stack_symbols.contains(symbol),
    }) catch return null;

    return rows.packSpan(span);
}
