const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const seed = @import("seed.zig");
const aggregate = @import("../aggregate.zig");
const conversion = @import("../state_value/conversion.zig");
const workflow = @import("generated_call_workflow");

pub fn lower(self: *Lower, invocation: seed.Operation) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return seed.lower(self, invocation);

    const selected = @import("policy.zig").analyze(self, invocation);

    switch (selected.route) {
        .Value => return @import("../value_call/root.zig").invocation(self, invocation),
        .Pointer => return @import("../value_call/root.zig").pointerInvocation(self, invocation),
        .Regular => {},
    }

    const plan = selected.regular.?;
    const function = @backingInt(invocation.function);
    const types = &self.program.functions;
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    var argument: node.ExpressionId = undefined;
    var store: ?node.ExpressionId = null;
    var result: node.ExpressionId = undefined;

    inline for (comptime zx.staticSequence(workflow, .Regular)) |step| switch (step) {
        .Evaluate => argument = switch (plan.argument) {
            .ExternalTuple => try externalTuple(self, &body, invocation.argument),
            .ScalarBorrow => try @import("../value_call/argument.zig").borrow(self, &body, invocation.argument),
            .StateBorrow, .StatePointer, .Value => try self.expr(invocation.argument),
        },
        .Adapt => switch (plan.argument) {
            .StateBorrow, .StatePointer => {
                const bound = try aggregate.bind(self, &body, argument);
                const mode: conversion.Mode = if (plan.argument == .StateBorrow) .borrow else .pointer;
                argument = try conversion.convert(self, &body, @fromBackingInt(types.input_types[function]), bound, mode);
            },
            else => {},
        },
        .Store => if (plan.stores) {
            store = try @import("../store.zig").adapter(self, invocation);
        },
        .Invoke => result = try @import("emission.zig").lower(self, .{
            .function = invocation.function,
            .value = argument,
            .store = store,
            .io = plan.io,
            .process = plan.process,
        }),
        .Convert => if (plan.convert_output) {
            const bound = try aggregate.bind(self, &body, result);

            result = try conversion.convert(self, &body, @fromBackingInt(types.output_types[function]), bound, .value);
        },
        .Finish => {
            const block = try body.finish(self.allocator);

            if (block.len != 0) result = try aggregate.finishStored(self, block, result, null);
        },
        else => @compileError("Invalid regular invocation step"),
    };

    return result;
}

fn externalTuple(self: *Lower, body: *@import("../../node/blocks.zig").Sequence, id: zx.ir.ExprId) Lower.Error!node.ExpressionId {
    const value = self.program.expression(id);
    const layout = try @import("../aggregate/sequence.zig").lower(self, id, value, value.value.tuple, true);
    const argument = try aggregate.bind(self, body, try self.cast(try self.layoutExpr(value.type_id), layout));

    return self.builder.expression(.{ .address_of = argument });
}
