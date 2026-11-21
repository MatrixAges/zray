const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_iteration_workflow") else void;

const Phase = if (generated) entry.Input else enum {
    Open,
    StateScope,
    Parameters,
    Ordinary,
    Projected,
};

const Step = if (generated) std.meta.Child(entry.Output) else enum {
    CreateState,
    Select,
    Prepare,
    EvaluateInitial,
    GuardInitial,
    PrepareFields,
    TrackChanges,
    ConvertInitial,
    Schedule,
    Renewals,
    EvaluateStep,
    Declare,
    EnterLoop,
    SavePrefix,
    WriteUpdate,
    Frame,
    Recover,
    Finish,
};

pub fn steps(comptime phase: Phase) []const Step {
    if (generated) return zx.staticSequence(entry, phase);

    return switch (phase) {
        .Open => &.{ .CreateState, .Select, .Prepare, .EvaluateInitial, .GuardInitial },
        .StateScope => &.{ .PrepareFields, .TrackChanges },
        .Parameters => &.{ .ConvertInitial, .Schedule, .Renewals },
        .Ordinary => &.{ .EvaluateStep, .Declare, .EnterLoop, .SavePrefix, .WriteUpdate, .Frame, .Recover, .Finish },
        .Projected => &.{ .Declare, .EvaluateStep, .EnterLoop, .SavePrefix, .WriteUpdate, .Frame, .Recover, .Finish },
    };
}
