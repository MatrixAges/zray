const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../builder.zig");
const call = @import("host.zig");

pub fn lower(builder: *Builder, function: ir.FunctionId, initial: ir.ExprId, stores: []const u32, field: u32) Builder.Error!ir.ExprId {
    const span = builder.expressionSpan(initial);
    const state_type = builder.expressionType(initial);
    const bool_type = @import("frontend").types.scalarId(.bool);
    const condition_parameter = try parameter(builder, "$loop_condition", state_type, span);
    const step_parameter = try parameter(builder, "$loop_state", state_type, span);
    const condition = try builder.seedExpression(.{ .type_id = bool_type, .span = span, .value = .{ .field = .{ .target = condition_parameter.reference, .index = field } } });

    try builder.expressions.reserveHeaders(builder.allocator, 1);

    const updated = try call.invoke(builder, function, step_parameter.reference, state_type, stores);
    const next = try builder.symbol("$loop_state", state_type, span);
    const result = try reference(builder, next, state_type, span);
    const bindings = try builder.allocator.dupe(ir.ScopeBinding, &.{.{ .symbol = next, .value = updated }});
    const body = try builder.seedExpression(.{ .type_id = state_type, .span = span, .value = .{ .scope = .{ .bindings = bindings, .result = result } } });

    return builder.seedExpression(.{
        .type_id = state_type,
        .span = span,
        .value = .{ .iteration = .{
            .initial = initial,
            .condition_parameter = condition_parameter.symbol,
            .parameter = step_parameter.symbol,
            .condition = condition,
            .body = body,
            .postcondition = false,
        } },
    });
}

fn parameter(builder: *Builder, name: []const u8, state_type: ir.TypeId, span: zx.Span) Builder.Error!struct { symbol: ir.SymbolId, reference: ir.ExprId } {
    const symbol = try builder.symbol(name, state_type, span);

    builder.symbols.ownership.items[@backingInt(symbol)] = .Borrowed;

    return .{ .symbol = symbol, .reference = try reference(builder, symbol, state_type, span) };
}

fn reference(builder: *Builder, symbol: ir.SymbolId, state_type: ir.TypeId, span: zx.Span) Builder.Error!ir.ExprId {
    return builder.seedExpression(.{ .type_id = state_type, .span = span, .value = .{ .reference = symbol } });
}
