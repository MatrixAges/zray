const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const intrinsic = @import("../intrinsics.zig");

pub fn lower(self: *Lower, items: []const ir.ExprId, values: []const node.ExpressionId) Lower.Error!node.ExpressionId {
    if (items.len == 0) return self.builder.string("");
    if (items.len == 1 and self.program.expression(items[0]).value == .string) return values[0];

    const strings = try self.allocator.alloc(node.ExpressionId, items.len);
    var buffers: std.ArrayList(node.Statement) = .empty;

    defer buffers.deinit(self.workspace);

    for (items, values, strings) |item, value, *text| {
        const scalar = self.program.typeOf(self.program.expression(item).type_id).scalar;

        text.* = switch (scalar) {
            .string => value,
            .bool => try self.builder.expression(.{ .conditional = .{ .condition = value, .yes = try self.builder.string("true"), .no = try self.builder.string("false") } }),
            .f32, .f64 => try intrinsic.standard(self, &.{ "fmt", "allocPrint" }, &.{ try self.builder.identifier("allocator"), try self.builder.string("{d}"), try self.builder.expression(.{ .tuple = try self.allocator.dupe(node.ExpressionId, &.{value}) }) }, true),
            else => try decimal(self, value, &buffers),
        };
    }

    const byte = try self.builder.expression(.{ .primitive = .u8 });
    const array = try self.builder.expression(.{ .array = .{ .element_type = try self.builder.expression(.{ .const_slice = byte }), .values = strings } });
    const result = try intrinsic.standard(self, &.{ "mem", "concat" }, &.{ try self.builder.identifier("allocator"), byte, try self.builder.expression(.{ .address_of = array }) }, true);

    if (buffers.items.len == 0) return result;

    const label = try self.fresh("template");

    try buffers.append(self.workspace, .{ .break_value = .{ .label = label, .value = result } });

    return self.builder.expression(.{ .block = .{ .label = label, .statements = try self.builder.statements(buffers.items) } });
}

fn decimal(self: *Lower, value: node.ExpressionId, buffers: *std.ArrayList(node.Statement)) Lower.Error!node.ExpressionId {
    const buffer_name = try self.fresh("digits");
    const buffer = try self.builder.identifier(buffer_name);

    const length = try intrinsic.standard(self, &.{ "fmt", "printInt" }, &.{
        try self.builder.expression(.{ .address_of = buffer }),
        value,
        try self.builder.expression(.{ .integer = 10 }),
        try self.builder.expression(.{ .enum_literal = "lower" }),
        try self.builder.expression(.{ .object = .{ .fields = &.{} } }),
    }, false);

    try buffers.append(self.workspace, .{ .variable = .{
        .name = buffer_name,
        .type_expr = try self.builder.expression(.{ .fixed_array_type = .{ .length = try self.builder.expression(.{ .integer = 32 }), .element = try self.builder.expression(.{ .primitive = .u8 }) } }),
        .value = try self.builder.expression(.undefined_value),
    } });

    return self.builder.expression(.{ .slice = .{ .target = buffer, .start = try self.builder.expression(.{ .integer = 0 }), .end = length } });
}
