const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Expressions = @import("../expressions.zig");
const Evaluation = @import("../terms.zig").Evaluation;
const Value = @import("../terms.zig").Value;
const terms = @import("../terms.zig");
const scalar = @import("../scalar.zig");
const rule = @import("generated_walk_symbolic_expression");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
const Input = std.meta.Child(rule.Input);
const Operand = native.SymbolicOperand;
pub const Columns = std.meta.Child(@FieldType(Input, "columns"));

pub const Frame = struct {
    evaluator: *Expressions,
    id: ir.ExprId,
    target: ir.TypeId,
    span: zx.Span,
    aggregate_fields: []Value = &.{},
    slots: [std.enums.values(Operand).len]Evaluation = undefined,
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

    var frame: Frame = .{ .evaluator = evaluator, .id = id, .target = target, .span = span };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .columns = &evaluator.columns.?,
        .id = @backingInt(id),
        .depth = depth,
    };

    rule.executeIn(evaluator.allocator, &input) catch |err| return @import("context.zig").failure(err);

    return frame.at(.Result).*;
}

pub fn rejectSymbolicExpression(handle: *anyopaque, message: []const u8) error{InvalidSource}!void {
    const frame = Frame.borrow(handle);

    return @errorCast(frame.evaluator.reporter.fail(.unsupported, frame.span, message));
}

pub fn loadSymbolicReference(handle: *anyopaque, symbol: u32) error{InvalidSource}!void {
    const frame = Frame.borrow(handle);

    const value = frame.evaluator.environment[symbol] orelse
        return @errorCast(frame.evaluator.reporter.fail(.contract, frame.span, "verification encountered an unbound symbol"));

    frame.at(.Result).* = .{ .value = value };
}

pub fn symbolicLiteralWidth(handle: *anyopaque, enumeration: bool) u64 {
    const frame = Frame.borrow(handle);
    const target = frame.evaluator.program.typeOf(frame.target);

    return if (enumeration) terms.enumWidth(target) else terms.integer(target).?.width;
}

pub fn writeSymbolicLiteral(handle: *anyopaque, text: []const u8) void {
    Frame.borrow(handle).at(.Result).* = .{ .value = .{ .scalar = text } };
}

pub fn evaluateSymbolicOperand(handle: *anyopaque, slot: Operand, expression: u32) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);
    const value = try frame.evaluator.evaluate(@fromBackingInt(expression));

    frame.at(slot).* = value;

    return value.safe;
}

pub fn symbolicOperandText(handle: *anyopaque, slot: Operand) []const u8 {
    return Frame.borrow(handle).at(slot).value.scalar;
}

pub fn symbolicOperandSafety(handle: *anyopaque, slot: Operand) []const u8 {
    return Frame.borrow(handle).at(slot).safe;
}

pub fn projectSymbolicOperand(handle: *anyopaque, index: u32) void {
    const frame = Frame.borrow(handle);
    const source = frame.at(.First);

    frame.at(.Result).* = .{ .value = source.value.fields[index], .safe = source.safe };
}

pub fn writeSymbolicUnary(handle: *anyopaque, invert: bool) zx.Error!bool {
    const frame = Frame.borrow(handle);
    const evaluator = frame.evaluator;
    const target = evaluator.program.typeOf(frame.target);
    const result = try scalar.unary(evaluator.allocator, invert, target, frame.at(.First).*) orelse return false;

    frame.at(.Result).* = result;

    return true;
}

pub fn writeSymbolicBinary(handle: *anyopaque, left: u32) zx.Error!bool {
    const frame = Frame.borrow(handle);
    const evaluator = frame.evaluator;
    const expressions = &evaluator.program.expressions;
    const target = evaluator.program.typeOf(@fromBackingInt(expressions.types[left]));
    const result = try scalar.binaryWithColumns(evaluator.allocator, expressions, frame.id, target, frame.at(.First).*, frame.at(.Second).*) orelse return false;

    frame.at(.Result).* = result;

    return true;
}

pub fn selectSymbolicExpression(handle: *anyopaque, condition: []const u8, yes: Operand, no: Operand) zx.Error!void {
    const frame = Frame.borrow(handle);
    const evaluator = frame.evaluator;

    frame.at(.Result).value = try evaluator.graph.select(evaluator.program, frame.target, condition, frame.at(yes).value, frame.at(no).value, frame.span);
}

pub fn retainSymbolicExpression(handle: *anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const result = frame.at(.Result);

    result.* = try frame.evaluator.retainAt(frame.target, frame.span, result.*);
}

pub fn bindSymbolicExpressionSafety(handle: *anyopaque, safe: []const u8) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);

    return frame.evaluator.boolean(safe, frame.span);
}

pub fn writeSymbolicSafety(handle: *anyopaque, safe: []const u8) void {
    Frame.borrow(handle).at(.Result).safe = safe;
}

pub fn reserveSymbolicAggregate(handle: *anyopaque, count: u32) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const fields = try frame.evaluator.allocator.alloc(Value, count);

    frame.aggregate_fields = fields;

    frame.at(.Result).* = .{ .value = .{ .fields = fields } };
}

pub fn writeSymbolicAggregateField(handle: *anyopaque, index: u32) void {
    const frame = Frame.borrow(handle);

    frame.aggregate_fields[index] = frame.at(.First).value;
}
