const std = @import("std");
const ir = @import("zx").ir;
const Level = @import("../level.zig").Level;
const generated = @import("genz_options").generated_analysis;
const transition = if (generated) @import("generated_uniqueness_round_phase") else void;
const Parameter = if (generated) @typeInfo(@TypeOf(transition.executeValue)).@"fn".param_types[1].? else void;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;

pub const Event = if (generated) @FieldType(Input, "event") else enum {
    Start,
    ReplayAccepted,
    ReplayRejected,
    Settled,
    Exhausted,
    DemandGrew,
    DemandStable,
    PlansPublished,
};

pub const Phase = if (generated) transition.Output else enum { Replay, Settled, Demanded, Planned, CommitTrace, Finished };
pub const Step = struct { phase: Phase, budget: u64 };
pub const Visit = union(enum) { done, exhausted, body: usize };

pub fn next(event: Event, following: bool, persistent: bool) Phase {
    if (generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: Input = .{ .event = event, .following = following, .persistent = persistent };

        return transition.executeValue(empty.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch unreachable;
    }

    return switch (event) {
        .Start => if (following) .Replay else .Settled,
        .ReplayAccepted => .Finished,
        .ReplayRejected, .DemandGrew => .Settled,
        .Settled, .Exhausted => .Demanded,
        .DemandStable => .Planned,
        .PlansPublished => if (persistent) .CommitTrace else .Finished,
    };
}

pub const Settlement = struct {
    program: *const ir.Program,
    outputs: [][]Level,
    dirty: []bool,
    changed: []const u64,
    callers: []const u64,
    body: usize,
    levels: []const Level,
};
