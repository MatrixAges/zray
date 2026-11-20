const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Analyzer = @import("../analyzer.zig");
const Types = @import("../types.zig");
const Builder = @import("builder.zig");
const Callback = @import("callback.zig").Result;
const iteration_plan = @import("iteration_plan.zig");

pub const Options = struct { tuple_result: bool = false, projection: ?u64 = null, span: zx.Span, kind: @FieldType(ir.Transform, "kind"), target: ir.ExprId, initial: ?ir.ExprId, ignored: ?ir.ExprId, callback: Callback, result_type: ir.TypeId };

pub fn lower(analyzer: *Analyzer, options: Options) zx.Error!ir.ExprId {
    if (options.kind == .sort) return @import("sorting.zig").lower(analyzer, options);

    const plan = iteration_plan.choose(options.kind, options.initial != null, options.tuple_result, options.projection);
    const builder = Builder{ .analyzer = analyzer, .span = options.span };
    const source_symbol = try builder.symbol("$collection_source", analyzer.node(options.target).type_id);
    const source = try builder.reference(source_symbol);
    var bindings: std.ArrayList(ir.ScopeBinding) = .empty;

    try bindings.append(analyzer.allocator, .{ .symbol = source_symbol, .value = options.target, .borrow = true });

    if (options.ignored) |ignored| {
        const type_id = analyzer.node(ignored).type_id;
        const symbol = if (type_id == Types.scalarId(.void)) null else try builder.symbol("$collection_argument", type_id);

        try bindings.append(analyzer.allocator, .{ .symbol = symbol, .value = ignored, .borrow = true });
    }

    const initial_result = switch (plan.initial) {
        .Empty => try builder.expression(options.result_type, .{ .list = &.{} }),
        .True, .False => try builder.expression(Types.scalarId(.bool), .{ .boolean = plan.initial == .True }),
        .Given => options.initial.?,
        .First => try builder.expression(options.result_type, .{ .index = .{ .target = source, .index = try builder.integer(0) } }),
    };

    var fields: std.ArrayList(Builder.Field) = .empty;

    try fields.appendSlice(analyzer.allocator, &.{
        .{ .name = "source", .value = source },
        .{ .name = "index", .value = try builder.integer(@intFromBool(plan.initial == .First)) },
        .{ .name = "result", .value = initial_result },
    });

    if (options.callback.captures.len != 0) {
        const values = try analyzer.allocator.alloc(ir.ExprId, options.callback.captures.len);

        for (options.callback.captures, values) |capture, *value| value.* = capture.value;
        try fields.append(analyzer.allocator, .{ .name = "captures", .value = try builder.tuple(values) });
    }

    const initial = try builder.object(fields.items);
    const state_type = analyzer.node(initial).type_id;
    const condition_parameter = try builder.symbol("$collection_condition", state_type);
    const parameter = try builder.symbol("$collection_state", state_type);

    analyzer.symbols.ownership.items[@backingInt(condition_parameter)] = .Borrowed;
    analyzer.symbols.ownership.items[@backingInt(parameter)] = .Borrowed;

    const iteration = try builder.expression(state_type, .{ .iteration = .{
        .initial = initial,
        .condition_parameter = condition_parameter,
        .parameter = parameter,
        .condition = try condition(builder, plan.condition, condition_parameter),
        .body = try @import("step.zig").build(builder, plan, parameter, options.callback),
        .postcondition = false,
    } });

    const result_symbol = try builder.symbol("$collection_result", state_type);

    try bindings.append(analyzer.allocator, .{ .symbol = result_symbol, .value = iteration });

    const value = try builder.field(try builder.reference(result_symbol), "result");

    const result = switch (plan.result) {
        .Value => value,
        .Source => source,
        .Unit => try builder.expression(Types.scalarId(.void), .unit),
        .SourceAndValue => try builder.tuple(&.{ source, value }),
        .ValueAndUnit => try builder.tuple(&.{ value, try builder.expression(Types.scalarId(.void), .unit) }),
    };

    return builder.expression(analyzer.node(result).type_id, .{ .scope = .{
        .bindings = try bindings.toOwnedSlice(analyzer.allocator),
        .result = result,
    } });
}

fn condition(builder: Builder, test_kind: @FieldType(iteration_plan.Plan, "condition"), parameter: ir.SymbolId) zx.Error!ir.ExprId {
    const current = try builder.reference(parameter);
    const length = try builder.expression(Types.scalarId(.u64), .{ .length = try builder.field(current, "source") });
    const bound = try builder.expression(Types.scalarId(.bool), .{ .binary = .{ .operator = .less, .left = try builder.field(current, "index"), .right = length } });

    if (test_kind == .Bound) return bound;

    const result = try builder.field(current, "result");
    const continuing = if (test_kind == .WhileTrue) result else try builder.expression(Types.scalarId(.bool), .{ .unary = .{ .operator = .not, .operand = result } });

    return builder.expression(Types.scalarId(.bool), .{ .binary = .{ .operator = .logical_and, .left = bound, .right = continuing } });
}
