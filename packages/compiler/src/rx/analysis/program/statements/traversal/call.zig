const Invocation = @import("../invocation.zig");
const State = @import("host.zig").State;
const Error = @import("../../statements.zig").Error;

pub fn prepareBodyCall(handle: *const anyopaque, item: u32) bool {
    const state = State.borrow(handle);
    const call = &state.statements.calls[item];

    state.call = .{ .call = call };

    return !call.input_omitted;
}

pub fn bindBodyGetters(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    try state.statements.bindGetters(state.writer, state.call.call);
}

pub fn evaluateBodyArgument(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    state.call.argument = try state.statements.evaluateArgument(state.call.call);
}

pub fn createBodyUnitArgument(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    state.call.argument = try state.statements.unitArgument(state.call.call);
}

pub fn resolveBodyCallStores(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    try state.call.resolveStores(state.statements.builder);
}

pub fn prepareBodyImport(handle: *const anyopaque) Error!bool {
    const state = State.borrow(handle);

    try Invocation.Import.prepare(state.statements.builder, state.call.call, &state.call.function);

    return state.call.function.addition != null;
}

pub fn appendBodyFunctionTail(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    try state.call.function.appendTail(state.statements.builder);
}

pub fn bodyHasInitializers(handle: *const anyopaque) bool {
    return State.borrow(handle).call.function.needs_initializers;
}

pub fn linkBodyInitializers(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    try state.call.function.linkInitializers(state.statements.builder, state.call.call);
}

pub fn appendBodyFunctionEntry(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    try state.call.function.appendEntry(state.statements.builder, state.call.call);
}

pub fn emitBodyCall(handle: *const anyopaque) Error!u32 {
    const state = State.borrow(handle);

    return @backingInt(try state.call.emit(state.statements.builder));
}

pub fn registerBodyCallResult(handle: *const anyopaque, value: u32, parallel: bool) Error!?u32 {
    const state = State.borrow(handle);
    const call = state.call.call;
    const name = call.out orelse return null;
    const builder = state.statements.builder;
    const id = @as(@import("zx").ir.ExprId, @fromBackingInt(value));
    const output = if (parallel) builder.expressionType(id) else call.callee.output_type;

    return @backingInt(try builder.symbol(name, output, builder.expressionSpan(id)));
}
