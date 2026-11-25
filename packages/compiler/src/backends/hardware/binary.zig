const std = @import("std");
const zx = @import("zx");
const ir = @import("ir.zig");
const rule = @import("generated_hardware_binary_traits");
pub const Traits = std.meta.Child(rule.Output);

const table = blk: {
    @setEvalBranchQuota(10000);

    var rows: std.enums.EnumArray(ir.Operator, Traits) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    for (std.enums.values(ir.Operator)) |operator| {
        const row = rule.executeValue(scratch.allocator(), operator) catch unreachable;

        rows.set(operator, .{ .smt = row.smt, .token = row.token, .family = row.family, .rendering = row.rendering });
    }

    break :blk rows;
};

pub const names = blk: {
    var pairs: [std.enums.values(ir.Operator).len]struct { []const u8, ir.Operator } = undefined;

    for (std.enums.values(ir.Operator), &pairs) |operator, *entry| entry.* = .{ table.get(operator).smt, operator };

    break :blk std.StaticStringMap(ir.Operator).initComptime(pairs);
};

pub fn traits(operator: ir.Operator) Traits {
    return table.get(operator);
}

pub fn result(operator: ir.Operator, left: ir.Sort, right: ir.Sort) ?ir.Sort {
    const family = table.get(operator).family;
    const boolean = ir.Sort{ .width = 1, .boolean = true };
    const derive = @import("generated_hardware_binary_result");

    const input: std.meta.Child(derive.Input) = .{
        .family = family,
        .left = &.{ .width = left.width, .boolean = left.boolean },
        .right = &.{ .width = right.width, .boolean = right.boolean },
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return switch (zx.columns.invoke(derive.executeValue, scratch.allocator(), &input) catch unreachable) {
        .Invalid => null,
        .Boolean => boolean,
        .Operand => left,
    };
}
