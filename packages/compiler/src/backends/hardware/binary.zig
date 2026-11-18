const std = @import("std");
const zx = @import("zx");
const ir = @import("ir.zig");
const generated = @import("parser_options").generated_parser;
const rule = if (generated) @import("generated_hardware_binary_traits") else void;
pub const Traits = if (generated) std.meta.Child(rule.Output) else @import("binary/seed.zig").Traits;

const table = blk: {
    @setEvalBranchQuota(10000);

    var rows: std.enums.EnumArray(ir.Operator, Traits) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    for (std.enums.values(ir.Operator)) |operator| {
        const row = if (generated) (rule.executeValue(scratch.allocator(), operator) catch unreachable) else @import("binary/seed.zig").traits(operator);

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

    if (comptime generated) {
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

    if (!left.equal(right)) return null;
    if (family != .Equality and left.boolean != (family == .Logical)) return null;

    return if (family == .Arithmetic) left else boolean;
}
