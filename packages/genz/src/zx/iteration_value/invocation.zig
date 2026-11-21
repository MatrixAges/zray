const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;
const workflow = if (generated) @import("generated_call_workflow") else void;
const Form = if (generated) workflow.Input else enum { IterationInput, IterationCall, IterationRestore };

const Step = if (generated) std.meta.Child(workflow.Output) else enum {
    Evaluate,
    Bind,
    View,
    Invoke,
    Convert,
    Finish,
    RestoreCache,
    RestoreArgument,
};

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const call = row.value.call;
    const argument = call.argument;
    const input_type: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[@backingInt(argument)]);
    var body: std.ArrayList(node.Statement) = .empty;
    var input: node.ExpressionId = undefined;

    inline for (comptime steps(.IterationInput)) |step| switch (step) {
        .Evaluate => input = try lowering.expr(argument),
        .Bind => input = try aggregate.bind(lowering, &body, input),
        .View => input = try @import("borrow.zig").lower(self, &body, input_type, input),
        else => @compileError("Invalid iteration input step"),
    };

    const previous = self.argument;

    const cached = installed: {
        self.argument = .{ .id = argument, .value = input };
        errdefer self.argument = previous;

        break :installed try lowering.cache.bind(lowering.allocator, argument, input);
    };

    defer {
        inline for (comptime steps(.IterationRestore)) |step| switch (step) {
            .RestoreCache => cached.restore(),
            .RestoreArgument => self.argument = previous,
            else => @compileError("Invalid iteration restore step"),
        };
    }

    var result: node.ExpressionId = undefined;

    inline for (comptime steps(.IterationCall)) |step| switch (step) {
        .Invoke => result = if (value_call)
            try @import("../value_call/root.zig").invocation(lowering, call)
        else
            try lowering.regular(id),
        .Bind => result = try aggregate.bind(lowering, &body, result),
        .Convert => result = try @import("conversion.zig").convert(self, row.type_id, result, false),
        .Finish => result = try aggregate.finish(lowering, &body, result),
        else => @compileError("Invalid iteration invocation step"),
    };

    return result;
}

fn steps(comptime form: Form) []const Step {
    if (generated) return zx.staticSequence(workflow, form);

    return switch (form) {
        .IterationInput => &.{ .Evaluate, .Bind, .View },
        .IterationCall => &.{ .Invoke, .Bind, .Convert, .Finish },
        .IterationRestore => &.{ .RestoreCache, .RestoreArgument },
    };
}
