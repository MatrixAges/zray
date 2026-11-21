const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
const workflow = if (generated) @import("generated_uniqueness_program") else void;

pub const Step = if (generated) workflow.Output else enum {
    Start,
    Replay,
    Open,
    Settle,
    Demand,
    ConservativeDemand,
    Plan,
    Release,
    ReleaseReused,
    Commit,
    Done,
};

const table = if (generated) build() else {};

fn build() [@typeInfo(Step).@"enum".field_names.len][2]Step {
    @setEvalBranchQuota(50_000);

    var result: [@typeInfo(Step).@"enum".field_names.len][2]Step = undefined;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    for (std.enums.values(Step)) |step| {
        for ([_]bool{ false, true }) |condition| {
            const input: std.meta.Child(workflow.Input) = .{ .step = step, .condition = condition };

            result[@backingInt(step)][@intFromBool(condition)] = zx.columns.invoke(workflow.executeValue, empty.allocator(), &input) catch unreachable;
        }
    }

    return result;
}

pub fn next(step: Step, condition: bool) Step {
    if (generated) return table[@backingInt(step)][@intFromBool(condition)];

    return switch (step) {
        .Start => if (condition) .Replay else .Open,
        .Replay => if (condition) .ReleaseReused else .Open,
        .Open => .Settle,
        .Settle => if (condition) .ConservativeDemand else .Demand,
        .Demand, .ConservativeDemand => if (condition) .Settle else .Plan,
        .Plan => .Release,
        .Release => if (condition) .Commit else .Done,
        .ReleaseReused, .Commit, .Done => .Done,
    };
}
