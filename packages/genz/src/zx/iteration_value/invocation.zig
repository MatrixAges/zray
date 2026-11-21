const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const call = row.value.call;
    const argument = call.argument;
    const input_type: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[@backingInt(argument)]);
    var body: std.ArrayList(node.Statement) = .empty;
    const input = try aggregate.bind(lowering, &body, try lowering.expr(argument));
    const view = try @import("borrow.zig").lower(self, &body, input_type, input);
    const previous = self.argument;

    self.argument = .{ .id = argument, .value = view };
    defer self.argument = previous;

    const cached = try lowering.cache.bind(lowering.allocator, argument, view);

    defer cached.restore();

    const invocation = if (value_call)
        try @import("../value_call/root.zig").invocation(lowering, call)
    else
        try lowering.regular(id);

    const result = try aggregate.bind(lowering, &body, invocation);
    const output = try @import("conversion.zig").convert(self, row.type_id, result, false);

    return aggregate.finish(lowering, &body, output);
}
