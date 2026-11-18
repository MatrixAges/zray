const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const seed = @import("scalar/seed.zig");
const generated = @import("parser_options").generated_parser;
const Evaluation = terms.Evaluation;

pub fn unary(allocator: std.mem.Allocator, invert: bool, target: ir.Type, operand: Evaluation) zx.Error!?Evaluation {
    if (operand.value != .scalar) return null;
    if (comptime !generated) return seed.unary(allocator, invert, target, operand);

    const rule = @import("generated_verification_unary");

    const input: std.meta.Child(rule.Input) = .{
        .invert = invert,
        .width = if (terms.integer(target)) |integer| integer.width else 0,
        .operand = &.{ .value = operand.value.scalar, .safe = operand.safe },
    };

    return evaluate(rule, allocator, &input);
}

pub fn binary(allocator: std.mem.Allocator, table: *const ir.ExpressionTable, id: ir.ExprId, operator: ir.Operator, target: ir.Type, left: Evaluation, right: Evaluation) zx.Error!?Evaluation {
    if (left.value != .scalar or right.value != .scalar) return null;
    if (comptime !generated) return seed.binary(allocator, operator, target, left, right);

    const rule = @import("generated_verification_binary");
    const Input = std.meta.Child(rule.Input);
    const operators = zx.columns.slice([]const @FieldType(Input, "operator"), table.binary_operators);
    const integer = terms.integer(target);

    const input: Input = .{
        .operator = operators[table.payloads[@backingInt(id)]],
        .width = if (integer) |number| number.width else 0,
        .signed = if (integer) |number| number.signed else false,
        .comparable = integer != null or target == .enumeration or (target == .scalar and target.scalar == .bool),
        .left = &.{ .value = left.value.scalar, .safe = left.safe },
        .right = &.{ .value = right.value.scalar, .safe = right.safe },
    };

    return evaluate(rule, allocator, &input);
}

fn evaluate(comptime rule: type, allocator: std.mem.Allocator, input: rule.Input) zx.Error!?Evaluation {
    const result = rule.executeValue(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IntegerOverflow => return error.InvalidSource,
    };

    return .{ .value = .{ .scalar = result.value orelse return null }, .safe = result.safe };
}
