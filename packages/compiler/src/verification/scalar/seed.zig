const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("../terms.zig");
const syntax = @import("../predicate/seed.zig");
const Evaluation = terms.Evaluation;

pub fn unary(allocator: std.mem.Allocator, invert: bool, target_type: ir.Type, operand: Evaluation) zx.Error!?Evaluation {
    if (invert) return .{ .value = .{ .scalar = try syntax.unary(allocator, "not", operand.value.scalar) }, .safe = operand.safe };

    const target = terms.integer(target_type) orelse return null;
    const minimum = try syntax.constant(allocator, @as(u64, 1) << @intCast(target.width - 1), target.width);
    const safe = try syntax.unary(allocator, "not", try syntax.binary(allocator, "=", operand.value.scalar, minimum));

    return .{ .value = .{ .scalar = try syntax.unary(allocator, "bvneg", operand.value.scalar) }, .safe = try syntax.binary(allocator, "and", operand.safe, safe) };
}

pub fn binary(allocator: std.mem.Allocator, operator: ir.Operator, target: ir.Type, left: Evaluation, right: Evaluation) zx.Error!?Evaluation {
    const a = left.value.scalar;
    const b = right.value.scalar;
    var safe = try syntax.binary(allocator, "and", left.safe, right.safe);

    if (operator == .logical_and or operator == .logical_or) {
        const conjunction = operator == .logical_and;
        safe = try syntax.binary(allocator, "and", left.safe, try syntax.choose(allocator, a, if (conjunction) right.safe else "true", if (conjunction) "true" else right.safe));

        return .{ .value = .{ .scalar = try syntax.binary(allocator, if (conjunction) "and" else "or", a, b) }, .safe = safe };
    }

    if (operator == .equal or operator == .not_equal) {
        if (terms.integer(target) == null and target != .enumeration and !(target == .scalar and target.scalar == .bool)) return null;

        const equal = try syntax.binary(allocator, "=", a, b);

        return .{ .value = .{ .scalar = if (operator == .equal) equal else try syntax.unary(allocator, "not", equal) }, .safe = safe };
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

    const value = try syntax.binary(allocator, mnemonic, a, b);

    switch (operator) {
        .add, .subtract, .multiply => {
            const extra: u16 = if (operator == .multiply) integer.width else 1;
            const extension = try std.fmt.allocPrint(allocator, "(_ {s} {d})", .{ if (integer.signed) "sign_extend" else "zero_extend", extra });
            const wide = try syntax.binary(allocator, mnemonic, try syntax.unary(allocator, extension, a), try syntax.unary(allocator, extension, b));
            const fits = try syntax.binary(allocator, "=", wide, try syntax.unary(allocator, extension, value));
            safe = try syntax.binary(allocator, "and", safe, fits);
        },
        .divide, .remainder => {
            const zero = try syntax.constant(allocator, 0, integer.width);
            safe = try syntax.binary(allocator, "and", safe, try syntax.unary(allocator, "not", try syntax.binary(allocator, "=", b, zero)));

            if (integer.signed and operator == .divide) {
                const minimum = try syntax.constant(allocator, @as(u64, 1) << @intCast(integer.width - 1), integer.width);
                const minus_one = try syntax.unary(allocator, "bvneg", try syntax.constant(allocator, 1, integer.width));
                const overflow = try syntax.binary(allocator, "and", try syntax.binary(allocator, "=", a, minimum), try syntax.binary(allocator, "=", b, minus_one));
                safe = try syntax.binary(allocator, "and", safe, try syntax.unary(allocator, "not", overflow));
            }
        },
        else => {},
    }

    return .{ .value = .{ .scalar = value }, .safe = safe };
}
