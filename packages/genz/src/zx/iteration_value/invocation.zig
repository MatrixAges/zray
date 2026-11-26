const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const previous = self.argument;
    defer self.argument = previous;

    var body: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;

    defer if (generated) body.deinit();

    const argument = row.value.call.argument;
    const value = try lowering.expr(argument);
    const input_type: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[@backingInt(argument)]);
    const bound_arg = try aggregate.bind(lowering, &body, value);
    const input = try @import("borrow.zig").lower(self, &body, input_type, bound_arg);

    self.argument = .{ .id = argument, .value = input };

    const cached = try lowering.cache.bind(lowering.allocator, argument, input);

    defer cached.restore();

    const invocation = if (value_call)
        try @import("../value_call/root.zig").invocation(lowering, row.value.call)
    else
        try lowering.regular(id);

    const bound_res = try aggregate.bind(lowering, &body, invocation);
    const converted = try @import("conversion.zig").convert(self, row.type_id, bound_res, false);

    return aggregate.finish(lowering, &body, converted);
}
