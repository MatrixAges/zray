const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub const Value = struct {
    scalar: ?[]const u8 = null,
    fields: []const Value = &.{},
    pub fn borrow(scalar: ?[]const u8, fields: []const u8) Value {
        if (fields.len == 0) return .{ .scalar = scalar };

        const bytes: []align(@alignOf(Value)) const u8 = @alignCast(fields);

        return .{ .scalar = scalar, .fields = std.mem.bytesAsSlice(Value, bytes) };
    }

    pub fn layout(comptime Layout: type) Layout {
        return .{
            .width = @sizeOf(Value),
            .text = @offsetOf(Value, "scalar"),
            .children = @offsetOf(Value, "fields"),
        };
    }
};

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

pub fn enumWidthForCount(count: usize) u16 {
    return @max(1, std.math.log2_int_ceil(usize, count));
}

/// A width of zero denotes an SMT Bool. Enumeration members share their bit-vector sort.
pub fn symbolicWidth(target: ir.Type) ?u16 {
    if (integer(target)) |number| return number.width;
    if (target == .enumeration) return enumWidthForCount(target.enumeration.members.len);
    if (target == .scalar and target.scalar == .bool) return 0;

    return null;
}
