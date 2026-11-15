const std = @import("std");
const generated = @import("rx_options").generated_graph;
const entry = if (generated) @import("generated_rx_module_constraints") else void;

pub const Form = if (generated) entry.Input else enum {
    ModuleShortcut,
    ModuleBody,
    CallWithArgument,
    CallWithoutArgument,
    Task,
    ParallelTask,
    Case,
    Default,
};

const Step = if (generated) std.meta.Child(entry.Output) else enum {
    Done,
    ForwardPorts,
    PublishShortcut,
    DefaultModuleOutput,
    MarkInput,
    CallInput,
    PublishGetters,
    InferArgument,
    VoidInput,
    CallOutput,
    PublishCall,
    EnterTask,
    InferBody,
    InferTaskOutput,
    DefaultTaskOutput,
    RequestTaskOutput,
    RestoreReturn,
    RestoreBindings,
    PublishTask,
    InferCaseLabel,
    InferDefaultLabel,
    RefineSubject,
    RestoreFacts,
};

const capacity = 7;

pub fn steps(comptime form: Form) [capacity]Step {
    var result: [capacity]Step = @splat(.Done);
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = if (generated) entry.executeValue(scratch.allocator(), form) catch unreachable else seed(form);

    @memcpy(result[0..sequence.len], sequence);

    return result;
}

fn seed(form: Form) []const Step {
    return switch (form) {
        .ModuleShortcut => &.{ .ForwardPorts, .PublishShortcut },
        .ModuleBody => &.{ .InferBody, .DefaultModuleOutput, .MarkInput },
        .CallWithArgument => &.{ .CallInput, .PublishGetters, .InferArgument, .RestoreBindings, .CallOutput, .PublishCall },
        .CallWithoutArgument => &.{ .CallInput, .VoidInput, .CallOutput, .PublishCall },
        .Task => &.{ .InferBody, .InferTaskOutput, .RestoreBindings, .PublishTask },
        .ParallelTask => &.{ .EnterTask, .InferBody, .DefaultTaskOutput, .RequestTaskOutput, .RestoreReturn, .RestoreBindings, .PublishTask },
        .Case => &.{ .InferCaseLabel, .RefineSubject, .InferBody, .RestoreFacts, .RestoreBindings },
        .Default => &.{ .InferDefaultLabel, .RefineSubject, .InferBody, .RestoreFacts, .RestoreBindings },
    };
}
