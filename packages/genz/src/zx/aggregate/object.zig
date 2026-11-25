const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub const Field = node.Field;

pub fn allocate(self: *Lower, scratch: std.mem.Allocator, count: usize) Lower.Error![]Field {
    _ = scratch;

    return self.allocator.alloc(Field, count);
}

pub fn operand(names: []const []const u8, index: u32, value: node.ExpressionId) Field {
    return .{ .name = names[index], .value = value };
}

pub const Request = struct {
    type_expr: node.ExpressionId,
    names: []const []const u8,
    indices: []const u32,
    fields: []const Field,
};

pub fn lower(self: *Lower, scratch: std.mem.Allocator, request: Request) Lower.Error!node.ExpressionId {
    _ = scratch;

    return self.builder.expression(.{ .object = .{ .type_expr = request.type_expr, .fields = request.fields } });
}
