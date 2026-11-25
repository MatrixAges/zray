const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
pub const Value = union(enum) { scalar: []const u8, fields: []const Value };
pub const Evaluation = struct { value: Value, safe: []const u8 = "true" };
pub const Integer = struct { width: u16, signed: bool };

pub fn integer(target: ir.Type) ?Integer {
    if (target != .scalar) return null;

    const mapped = comptime blk: {
        var entries: [std.enums.values(ir.Scalar).len]?Integer = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        for (std.enums.values(ir.Scalar)) |scalar| {
            const traits = @import("generated_verification_numeric").executeValue(scratch.allocator(), @backingInt(scalar)) catch unreachable;

            entries[@backingInt(scalar)] = if (traits.width == 0) null else .{ .width = @intCast(traits.width), .signed = traits.signed };
        }

        break :blk entries;
    };

    return mapped[@backingInt(target.scalar)];
}

pub fn enumWidth(target: ir.Type) u16 {
    return enumWidthForCount(target.enumeration.members.len);
}

pub fn enumWidthForCount(count: usize) u16 {
    return @max(1, std.math.log2_int_ceil(usize, count));
}

/// A width of zero denotes an SMT Bool. Enumeration members share their bit-vector sort.
pub fn symbolicWidth(target: ir.Type) ?u16 {
    if (integer(target)) |number| return number.width;
    if (target == .enumeration) return enumWidth(target);
    if (target == .scalar and target.scalar == .bool) return 0;

    return null;
}

const Operator = @FieldType(std.meta.Child(@import("generated_verification_connect").Input), "operator");

pub fn connect(allocator: std.mem.Allocator, operator: Operator, left: []const u8, right: []const u8) zx.Error![]const u8 {
    return @import("generated_verification_connect").executeValue(allocator, &.{ .operator = operator, .left = left, .right = right });
}

pub fn exclude(allocator: std.mem.Allocator, path: []const u8, predicate: []const u8) zx.Error![]const u8 {
    const rule = @import("generated_verification_exclude");
    const input: std.meta.Child(rule.Input) = .{ .left = path, .right = predicate };

    return zx.columns.invoke(rule.executeValue, allocator, &input);
}

pub fn choose(allocator: std.mem.Allocator, condition: []const u8, yes: []const u8, no: []const u8) zx.Error![]const u8 {
    const rule = @import("generated_verification_choose");
    const input: std.meta.Child(rule.Input) = .{ .condition = condition, .yes = yes, .no = no };

    return zx.columns.invoke(rule.executeValue, allocator, &input);
}

pub fn guarded(allocator: std.mem.Allocator, condition: []const u8, safe: []const u8, yes: []const u8, no: []const u8) zx.Error![]const u8 {
    return @import("generated_verification_guard").executeValue(allocator, &.{ .condition = condition, .safe = safe, .yes = yes, .no = no });
}

pub fn literal(allocator: std.mem.Allocator, value: u64, width: u16, negative: bool) zx.Error![]const u8 {
    return @import("generated_verification_literal").executeValue(allocator, &.{ .value = value, .width = width, .negative = negative });
}
