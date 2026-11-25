const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Operation = @FieldType(@FieldType(ir.ExpressionRow, "value"), "conditional");

pub fn lower(self: *Lower, value: Operation) Lower.Error!node.ExpressionId {
    return construct(self, try self.expr(value.condition), try self.expr(value.yes), try self.expr(value.no));
}

pub fn construct(self: *Lower, condition: node.ExpressionId, yes: node.ExpressionId, no: node.ExpressionId) Lower.Error!node.ExpressionId {
    return self.builder.expression(.{ .conditional = .{ .condition = condition, .yes = yes, .no = no } });
}
