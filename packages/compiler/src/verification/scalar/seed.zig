const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("../terms.zig");
const Evaluation = terms.Evaluation;

pub fn unary(allocator: std.mem.Allocator, invert: bool, target_type: ir.Type, operand: Evaluation) zx.Error!?Evaluation {
    if (invert) return .{ .value = .{ .scalar = try terms.unary(allocator, "not", operand.value.scalar) }, .safe = operand.safe };

    const target = terms.integer(target_type) orelse return null;
    const minimum = try terms.constant(allocator, @as(u64, 1) << @intCast(target.width - 1), target.width);
    const safe = try terms.unary(allocator, "not", try terms.binary(allocator, "=", operand.value.scalar, minimum));

    return .{ .value = .{ .scalar = try terms.unary(allocator, "bvneg", operand.value.scalar) }, .safe = try terms.binary(allocator, "and", operand.safe, safe) };
}

pub fn binary(allocator: std.mem.Allocator, operator: ir.Operator, target: ir.Type, left: Evaluation, right: Evaluation) zx.Error!?Evaluation {
    const a = left.value.scalar;
    const b = right.value.scalar;
    var safe = try terms.binary(allocator, "and", left.safe, right.safe);

    if (operator == .logical_and or operator == .logical_or) {
        const conjunction = operator == .logical_and;
        safe = try terms.binary(allocator, "and", left.safe, try terms.choose(allocator, a, if (conjunction) right.safe else "true", if (conjunction) "true" else right.safe));

        return .{ .value = .{ .scalar = try terms.binary(allocator, if (conjunction) "and" else "or", a, b) }, .safe = safe };
    }

    if (operator == .equal or operator == .not_equal) {
        if (terms.integer(target) == null and target != .enumeration and !(target == .scalar and target.scalar == .bool)) return null;

        const equal = try terms.binary(allocator, "=", a, b);

        return .{ .value = .{ .scalar = if (operator == .equal) equal else try terms.unary(allocator, "not", equal) }, .safe = safe };
    }

    const integer = terms.integer(target) orelse return null;

    const mnemonic: []const u8 = switch (operator) {
        .add => "bvadd",
        .subtract => "bvsub",
        .multiply => "bvmul",
        .divide => if (integer.signed) "bvsdiv" else "bvudiv",
        .remainder => if (integer.signed) "bvsrem" else "bvurem",
        .less => if (integer.signed) "bvslt" else "bvult",
        .less_equal => if (integer.signed) "bvsle" else "bvule",
        .greater => if (integer.signed) "bvsgt" else "bvugt",
        .greater_equal => if (integer.signed) "bvsge" else "bvuge",
        else => return null,
    };

    const value = try terms.binary(allocator, mnemonic, a, b);

    switch (operator) {
        .add, .subtract, .multiply => {
            const extra: u16 = if (operator == .multiply) integer.width else 1;
            const extension = try std.fmt.allocPrint(allocator, "(_ {s} {d})", .{ if (integer.signed) "sign_extend" else "zero_extend", extra });
            const wide = try terms.binary(allocator, mnemonic, try terms.unary(allocator, extension, a), try terms.unary(allocator, extension, b));
            const fits = try terms.binary(allocator, "=", wide, try terms.unary(allocator, extension, value));

            safe = try terms.binary(allocator, "and", safe, fits);
        },
        .divide, .remainder => {
            const zero = try terms.constant(allocator, 0, integer.width);

            safe = try terms.binary(allocator, "and", safe, try terms.unary(allocator, "not", try terms.binary(allocator, "=", b, zero)));

            if (integer.signed and operator == .divide) {
                const minimum = try terms.constant(allocator, @as(u64, 1) << @intCast(integer.width - 1), integer.width);
                const minus_one = try terms.unary(allocator, "bvneg", try terms.constant(allocator, 1, integer.width));
                const overflow = try terms.binary(allocator, "and", try terms.binary(allocator, "=", a, minimum), try terms.binary(allocator, "=", b, minus_one));
                safe = try terms.binary(allocator, "and", safe, try terms.unary(allocator, "not", overflow));
            }
        },
        else => {},
    }

    return .{ .value = .{ .scalar = value }, .safe = safe };
}
