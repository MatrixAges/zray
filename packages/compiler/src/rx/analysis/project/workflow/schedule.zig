const std = @import("std");
const zx = @import("zx");
const enabled = @import("rx_options").generated_graph;
const schedule = if (enabled) @import("generated_rx_workflow_sequence") else void;
const history = if (enabled) @import("generated_rx_workflow_history") else void;
const Phase = if (enabled) schedule.Input else enum { FreshProject, RetainedProject, Derive, Solve, Window, Finish };

const Step = if (enabled) std.meta.Child(schedule.Output) else enum {
    NormalizeSources,
    DeriveFrame,
    CompileBodies,
    PublishStores,
    RestoreFrame,
    RetainStores,
    PrepareModules,
    CollectGraph,
    OrderSignatures,
    ReadSignatures,
    IndexSignatures,
    LoadStores,
    PrepareFlow,
    SolveFlow,
    CompleteShortcuts,
    PublishFrame,
    CollectConstraints,
    FinishConstraints,
    ResolveConstraints,
    PrepareWindow,
    RestorePrefix,
    DispatchBody,
    RecordBody,
    MaterializeOutput,
    PublishExports,
    RetainHistory,
};

pub const Reuse = if (enabled) history.Output else enum { Fresh, Signatures, Frame };

pub fn select(previous: bool, bodies_only: bool, stores: usize) Reuse {
    if (comptime enabled) {
        const input: std.meta.Child(history.Input) = .{ .previous = previous, .bodies_only = bodies_only, .stores = stores };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.invoke(history.executeValue, empty.allocator(), &input) catch unreachable;
    }

    if (!previous) return .Fresh;
    if (bodies_only) return .Frame;

    return if (stores == 0) .Signatures else .Fresh;
}

pub fn steps(comptime phase: Phase) []const Step {
    if (comptime enabled) return @import("../sequence.zig").steps(schedule, phase);

    return switch (phase) {
        .FreshProject => &.{ .NormalizeSources, .DeriveFrame, .CompileBodies, .PublishStores },
        .RetainedProject => &.{ .NormalizeSources, .RestoreFrame, .CompileBodies, .RetainStores },
        .Derive => &.{ .PrepareModules, .CollectGraph, .OrderSignatures, .ReadSignatures, .IndexSignatures, .LoadStores, .PrepareFlow, .SolveFlow, .CompleteShortcuts, .PublishFrame },
        .Solve => &.{ .CollectConstraints, .FinishConstraints, .ResolveConstraints },
        .Window => &.{ .PrepareWindow, .RestorePrefix, .DispatchBody, .RecordBody },
        .Finish => &.{ .MaterializeOutput, .PublishExports, .RetainHistory },
    };
}
