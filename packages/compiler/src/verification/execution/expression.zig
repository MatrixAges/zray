const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Expressions = @import("../expressions.zig");
const Evaluation = @import("../terms.zig").Evaluation;
const Value = @import("../terms.zig").Value;
const rule = @import("generated_walk_symbolic_expression");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
const Input = std.meta.Child(rule.Input);
const Operand = native.SymbolicOperand;

pub const Columns = std.meta.Child(@FieldType(Input, "columns"));
pub const Types = std.meta.Child(@FieldType(Input, "types"));

pub const Frame = struct {
    evaluator: *Expressions,
    id: ir.ExprId,
    target: ir.TypeId,
    span: zx.Span,
    call_safety: native.CallSafety = undefined,
    slots: [std.enums.values(Operand).len]Evaluation = undefined,
    outcomes: [std.enums.values(Operand).len]native.SymbolicOutcome = undefined,
    pub fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
    pub fn at(frame: *@This(), slot: Operand) *Evaluation {
        return &frame.slots[@backingInt(slot)];
    }
};

pub fn execute(evaluator: *Expressions, id: ir.ExprId, target: ir.TypeId, span: zx.Span) zx.Error!Evaluation {
    const depth = evaluator.depth;
    evaluator.depth += 1;
    defer evaluator.depth = depth;

    if (evaluator.columns == null) {
        const expressions: *const ir.ExpressionTable = &evaluator.program.expressions;

        evaluator.columns = zx.columns.borrow(Columns, expressions);
    }

    if (evaluator.types == null) {
        const types: *const zx.ir.TypeTable = &evaluator.program.types;

        evaluator.types = zx.columns.borrow(Types, types);
    }

    var frame: Frame = .{ .evaluator = evaluator, .id = id, .target = target, .span = span };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .columns = &evaluator.columns.?,
        .types = &evaluator.types.?,
        .id = @backingInt(id),
        .depth = depth,
    };

    const outcome = zx.columns.invoke(rule.executeIn, evaluator.allocator, &input) catch |err| return @import("context.zig").failure(err);

    if (outcome.diagnostic) |message| return evaluator.reporter.fail(.unsupported, span, message);

    if (outcome.projection) |index| {
        const source = frame.at(.First);

        return .{ .value = source.value.fields[index], .safe = source.safe };
    }

    if (outcome.fields) |rows| {
        const fields = try evaluator.allocator.alloc(Value, rows.len);

        for (rows) |field| fields[field.index] = Value.borrow(field.text, field.fields);

        return .{ .value = .{ .fields = fields }, .safe = outcome.safe orelse "true" };
    }

    if (outcome.scalar) |text| {
        frame.at(.Result).* = .{
            .value = .{ .scalar = text },
            .safe = outcome.safe orelse "true",
        };
    } else if (outcome.safe) |safe| {
        frame.at(.Result).safe = safe;
    }

    return frame.at(.Result).*;
}

pub fn loadSymbolicReference(handle: *anyopaque, symbol: u32) error{InvalidSource}!void {
    const frame = Frame.borrow(handle);

    const value = frame.evaluator.environment[symbol] orelse
        return @errorCast(frame.evaluator.reporter.fail(.contract, frame.span, "verification encountered an unbound symbol"));

    frame.at(.Result).* = .{ .value = value };
}

pub fn evaluateSymbolicOperand(handle: *anyopaque, slot: Operand, expression: u32) zx.Error!*const native.SymbolicOutcome {
    const frame = Frame.borrow(handle);
    const value = try frame.evaluator.evaluate(@fromBackingInt(expression));

    frame.at(slot).* = value;

    const outcome = &frame.outcomes[@backingInt(slot)];

    outcome.* = .{
        .safe = value.safe,
        .text = value.value.scalar,
        .fields = std.mem.sliceAsBytes(value.value.fields),
    };

    return outcome;
}

pub fn selectSymbolicExpression(handle: *anyopaque, condition: []const u8, yes: Operand, no: Operand) zx.Error!void {
    const frame = Frame.borrow(handle);
    const evaluator = frame.evaluator;

    frame.at(.Result).value = try evaluator.graph.select(evaluator.program, frame.target, condition, frame.at(yes).value, frame.at(no).value, frame.span);
}

pub fn retainSymbolicExpression(handle: *anyopaque, safe: []const u8) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);
    const result = frame.at(.Result);
    result.* = try frame.evaluator.retainAt(frame.target, frame.span, .{ .value = result.value, .safe = safe });

    return result.safe;
}

pub fn bindSymbolicExpressionSafety(handle: *anyopaque, safe: []const u8) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);

    return frame.evaluator.boolean(safe, frame.span);
}
