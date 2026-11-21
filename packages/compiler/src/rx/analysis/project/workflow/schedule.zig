const std = @import("std");
const zx = @import("zx");
const enabled = @import("rx_options").generated_graph;
const schedule = if (enabled) @import("generated_rx_workflow_sequence") else void;
const Phase = if (enabled) schedule.Input else enum { Window, Finish };

const Step = if (enabled) std.meta.Child(schedule.Output) else enum {
    PrepareWindow,
    RestorePrefix,
    DispatchBody,
    RecordBody,
    MaterializeOutput,
    PublishExports,
    RetainHistory,
};

pub fn errorSet(err: anyerror) zx.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSource => error.InvalidSource,
        else => unreachable,
    };
}

pub fn steps(comptime phase: Phase) []const Step {
    if (comptime enabled) return @import("zx").staticSequence(schedule, phase);

    return switch (phase) {
        .Window => &.{ .PrepareWindow, .RestorePrefix, .DispatchBody, .RecordBody },
        .Finish => &.{ .MaterializeOutput, .PublishExports, .RetainHistory },
    };
}
