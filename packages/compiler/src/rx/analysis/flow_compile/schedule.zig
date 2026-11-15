const std = @import("std");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_flow_compile_schedule") else void;
pub const Form = if (generated) rule.Input else enum { Call, Task, Parallel, Selection, Case, ParallelTask };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    Done,
    BindGetters,
    CompileArgument,
    RestoreBindings,
    PublishCall,
    CompileTaskBody,
    CompileTaskOutput,
    PublishTask,
    CompileParallelBranches,
    PublishParallelBindings,
    CompileSubject,
    CompileCases,
    CheckSelection,
    CompileLabel,
    RefineSubject,
    CompileCaseBody,
    RestoreCaseScope,
    WriteCase,
    CompileParallelTaskBody,
    CheckTaskCalls,
    ResolveCaptures,
    LowerParallelTask,
    CheckTaskProgram,
    AnalyzeTaskOwnership,
    ValidateTaskProgram,
    BuildCaptureArgument,
    PublishParallelTask,
};

const capacity = 9;

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
        .Call => &.{ .BindGetters, .CompileArgument, .RestoreBindings, .PublishCall },
        .Task => &.{ .CompileTaskBody, .CompileTaskOutput, .RestoreBindings, .PublishTask },
        .Parallel => &.{ .CompileParallelBranches, .PublishParallelBindings },
        .Selection => &.{ .CompileSubject, .CompileCases, .CheckSelection },
        .Case => &.{ .CompileLabel, .RefineSubject, .CompileCaseBody, .RestoreCaseScope, .WriteCase },
        .ParallelTask => &.{ .CompileParallelTaskBody, .CheckTaskCalls, .ResolveCaptures, .LowerParallelTask, .CheckTaskProgram, .AnalyzeTaskOwnership, .ValidateTaskProgram, .BuildCaptureArgument, .PublishParallelTask },
    };
}
