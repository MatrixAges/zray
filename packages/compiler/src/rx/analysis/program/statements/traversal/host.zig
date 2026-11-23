const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Statements = @import("../../statements.zig");
const Plan = @import("../../control/plan.zig");
const Writer = @import("../../control/writer.zig");
const Invocation = @import("../invocation.zig");
const inlineValue = @import("../../expression.zig").inlineValue;
const Error = Statements.Error;

const Scope = struct {
    bindings: usize,
    value: ?ir.ExprId,
};

pub const State = struct {
    statements: *const Statements,
    allocator: std.mem.Allocator,
    root: u32,
    root_writer: *Writer.Cursor,
    scopes: []Scope = undefined,
    writers: []Writer.Cursor = undefined,
    row: *const Plan.Row = undefined,
    writer: *Writer.Cursor = undefined,
    call: Invocation = undefined,
    pub fn borrow(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn reserveBodyStatements(handle: *const anyopaque, slots: u64) Error!void {
    const state = State.borrow(handle);

    state.scopes = try state.allocator.alloc(Scope, @intCast(slots));
    state.writers = try state.allocator.alloc(Writer.Cursor, state.statements.plan.rows[state.root].tag);
}

pub fn selectBodyWriter(handle: *const anyopaque, block: u32) void {
    const state = State.borrow(handle);

    state.row = &state.statements.plan.rows[block];
    state.writer = if (block == state.root) state.root_writer else &state.writers[state.row.tag];
}

pub fn bodyBindingCount(handle: *const anyopaque) u64 {
    return State.borrow(handle).statements.builder.bindings.items.len;
}

pub fn restoreBodyBindings(handle: *const anyopaque, len: u64) void {
    State.borrow(handle).statements.restoreBindings(@intCast(len));
}

pub fn saveBodyScope(handle: *const anyopaque, slot: u32, value: ?u32) void {
    const state = State.borrow(handle);

    state.scopes[slot] = .{
        .bindings = state.statements.builder.bindings.items.len,
        .value = if (value) |id| @fromBackingInt(id) else null,
    };
}

pub fn restoreBodyScope(handle: *const anyopaque, slot: u32) void {
    const state = State.borrow(handle);

    state.statements.restoreBindings(state.scopes[slot].bindings);
}

pub fn evaluateBodyValue(handle: *const anyopaque, row: u32, borrowed: bool) Error!u32 {
    return @backingInt(try State.borrow(handle).statements.evaluateValue(row, borrowed));
}

pub fn emitBodyReturn(handle: *const anyopaque, value: u32) void {
    const state = State.borrow(handle);

    state.statements.writer.result(state.writer, @fromBackingInt(value));
}

pub fn emitBodyEvaluation(handle: *const anyopaque, value: u32) void {
    const state = State.borrow(handle);

    state.statements.writer.evaluate(state.writer, @fromBackingInt(value));
}

pub fn defineBodyTaskBinding(handle: *const anyopaque, row: u32, value: u32) Error!u32 {
    const state = State.borrow(handle);

    return @backingInt(try state.statements.defineTaskBinding(state.writer, row, @fromBackingInt(value)));
}

pub fn publishBodyBinding(handle: *const anyopaque, symbol: u32) Error!void {
    try State.borrow(handle).statements.publishBinding(@fromBackingInt(symbol));
}

pub fn evaluateBodyCaseLabel(handle: *const anyopaque, row: u32) Error!?u32 {
    const state = State.borrow(handle);
    const program = state.statements.flow.cases.items(.value)[row] orelse return null;

    return @backingInt(try inlineValue(state.statements.builder, program.*, false));
}

pub fn initializeBodyCase(handle: *const anyopaque) void {
    const state = State.borrow(handle);

    state.writer.* = Writer.Cursor.init(state.row.first);
}

pub fn emitBodyCase(handle: *const anyopaque, slot: u32, row: u32, end: u32) Error!void {
    const state = State.borrow(handle);

    try state.statements.writer.finishCase(state.writer, state.row.tag, &state.statements.plan.rows[end].first, row, state.scopes[slot].value);
}

pub fn emitBodySelection(handle: *const anyopaque, slot: u32, count: u32, exhaustive: bool) void {
    const state = State.borrow(handle);

    state.statements.writer.selection(state.writer, state.scopes[slot].value.?, count, exhaustive);
}
