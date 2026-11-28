const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const evaluation = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const operand = row.value.call.argument;
    const operand_type = lowering.program.expressions.types[@backingInt(operand)];
    const previous = self.argument;
    const previous_binding = self.argument_binding;
    const previous_body = self.active_body;
    var body: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;
    self.argument_binding = null;
    self.active_body = &body;

    defer {
        if (self.argument_binding) |binding| binding.restore();

        self.argument = previous;
        self.argument_binding = previous_binding;
        self.active_body = previous_body;
    }

    defer if (generated) body.deinit();

    if (!generated) {
        const value = try lowering.expr(operand);
        const bound = try aggregate.bind(lowering, &body, value);

        try install(self, &body, operand, @fromBackingInt(operand_type), bound);

        const invocation = if (value_call)
            try @import("../value_call/root.zig").invocation(lowering, row.value.call)
        else
            try lowering.regular(id);

        const result = try aggregate.bind(lowering, &body, invocation);
        const converted = try @import("conversion.zig").convert(self, row.type_id, result, false);

        return aggregate.finish(lowering, &body, converted);
    }

    const entry = @import("generated_lower_iteration_call");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(lowering),
        .context = @ptrCast(self),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(&body),
        .call_id = @backingInt(id),
        .operand = @backingInt(operand),
        .operand_type = operand_type,
        .result_type = @backingInt(row.type_id),
        .value_call = value_call,
    };

    return evaluation.invokeWith(lowering, entry, &input);
}

fn install(context: *Context, body: *Context.Statements, argument: ir.ExprId, type_id: ir.TypeId, value: node.ExpressionId) Lower.Error!void {
    const self = context.lowering;
    const input = try @import("borrow.zig").lower(context, body, type_id, value);

    context.argument = .{ .id = argument, .value = input };
    context.argument_binding = try self.cache.bind(self.allocator, argument, input);
}

pub fn openIterationCall(context_handle: *anyopaque, operand: u32, operand_type: u32, value: u32) Lower.Error!void {
    const context: *Context = @ptrCast(@alignCast(context_handle));

    return install(context, context.active_body.?, @fromBackingInt(operand), @fromBackingInt(operand_type), @fromBackingInt(value));
}

pub fn convertIterationCall(handle: *anyopaque, result_type: u32, value: u32) Lower.Error!u32 {
    const context: *Context = @ptrCast(@alignCast(handle));

    return @backingInt(try @import("conversion.zig").convert(context, @fromBackingInt(result_type), @fromBackingInt(value), false));
}
