const Invocation = @import("../invocation.zig");
const State = @import("host.zig").State;
const Error = @import("../../statements.zig").Error;
const ExprId = @import("zx").ir.ExprId;

pub fn apply(state: *State, effect: anytype, reply: anytype) Error!void {
    const statements = state.statements;
    const builder = statements.builder;

    switch (effect.step) {
        .PrepareCall => reply.explicit_input = prepare(state, effect.item.?),
        .BindGetters => try statements.bindGetters(state.writer, state.call.call),
        .EvaluateArgument => state.call.argument = try statements.evaluateArgument(state.call.call),
        .CreateUnit => state.call.argument = try statements.unitArgument(state.call.call),
        .ResolveStores => {
            statements.restoreBindings(state.call_binding_count);

            try state.call.resolveStores(builder);
        },
        .PrepareImport => {
            const function = &state.call.function;

            try Invocation.Import.prepare(builder, state.call.call, function);

            reply.addition = function.addition != null;
            reply.needs_initializers = function.needs_initializers;
        },
        .AppendTail => try state.call.function.appendTail(builder),
        .LinkInitializers => try state.call.function.linkInitializers(builder, state.call.call),
        .AppendEntry => try state.call.function.appendEntry(builder, state.call.call),
        .EmitCall => reply.id = @backingInt(try state.call.emit(builder)),
        .RegisterResult => reply.optional_id = try registerResult(state, effect.value.?, effect.parallel.?),
        else => unreachable,
    }
}

fn prepare(state: *State, item: u32) bool {
    const call = &state.statements.calls[item];

    state.call = .{ .call = call };
    state.call_binding_count = state.statements.builder.bindings.items.len;

    return !call.input_omitted;
}

fn registerResult(state: *State, value: u32, parallel: bool) Error!?u32 {
    const call = state.call.call;
    const name = call.out orelse return null;
    const builder = state.statements.builder;
    const id = @as(ExprId, @fromBackingInt(value));
    const output = if (parallel) builder.expressionType(id) else call.callee.output_type;

    return @backingInt(try builder.symbol(name, output, builder.expressionSpan(id)));
}
