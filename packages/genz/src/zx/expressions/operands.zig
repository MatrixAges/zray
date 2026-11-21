const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const entry = @import("generated_expression_operands");

pub fn evaluate(self: *Lower, comptime form: entry.Input, ids: []const ir.ExprId) Lower.Error![steps(form).len]node.ExpressionId {
    const order = comptime steps(form);
    const value = @import("../value_call/root.zig").expression;
    var result: [order.len]node.ExpressionId = undefined;

    inline for (order, &result) |step, *operand| {
        operand.* = try switch (step) {
            .First => self.expr(ids[0]),
            .Second => self.expr(ids[1]),
            .Third => self.expr(ids[2]),
            .SecondValue => value(self, ids[1]),
            .ThirdValue => value(self, ids[2]),
            .FirstType => self.typeExpr(@fromBackingInt(self.program.expressions.types[@backingInt(ids[0])])),
        };
    }

    return result;
}

fn steps(comptime form: entry.Input) []const @import("std").meta.Child(entry.Output) {
    return zx.staticSequence(entry, form);
}
