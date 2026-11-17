const std = @import("std");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_statement_schedule") else void;

pub const Form = if (generated) rule.Input else enum {
    CallWithArgument,
    CallWithoutArgument,
    Task,
    TaskWithEvaluation,
    TaskWithBinding,
    ImportFunctions,
    ImportFunctionsAndInitializers,
};

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    Done,
    BindGetters,
    EvaluateArgument,
    UnitArgument,
    RestoreBindings,
    ResolveStores,
    ImportCallee,
    AppendFunctionTail,
    LinkInitializers,
    AppendFunctionEntry,
    WriteCall,
    EvaluateTaskOutput,
    WriteEvaluation,
    DefineTaskBinding,
    PublishTaskBinding,
};

const capacity = 6;

pub fn steps(comptime form: Form) [capacity]Step {
    var result: [capacity]Step = @splat(.Done);
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = if (generated) rule.executeValue(scratch.allocator(), form) catch unreachable else seed(form);

    @memcpy(result[0..sequence.len], sequence);

    return result;
}

fn seed(form: Form) []const Step {
    return switch (form) {
        .CallWithArgument => &.{ .BindGetters, .EvaluateArgument, .RestoreBindings, .ResolveStores, .ImportCallee, .WriteCall },
        .CallWithoutArgument => &.{ .BindGetters, .UnitArgument, .RestoreBindings, .ResolveStores, .ImportCallee, .WriteCall },
        .Task => &.{.RestoreBindings},
        .TaskWithEvaluation => &.{ .EvaluateTaskOutput, .WriteEvaluation, .RestoreBindings },
        .TaskWithBinding => &.{ .EvaluateTaskOutput, .DefineTaskBinding, .RestoreBindings, .PublishTaskBinding },
        .ImportFunctions => &.{ .AppendFunctionTail, .AppendFunctionEntry },
        .ImportFunctionsAndInitializers => &.{ .AppendFunctionTail, .LinkInitializers, .AppendFunctionEntry },
    };
}
