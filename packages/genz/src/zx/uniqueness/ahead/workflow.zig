const std = @import("std");
const Memo = @import("../memo.zig");
const generated = @import("genz_options").generated_analysis;
const source = @import("generated_uniqueness_ahead_sequence");
const Activity = if (generated) @FieldType(std.meta.Child(source.Input), "activity") else enum { Request, Analyze, Collect };
const Step = if (generated) std.meta.Child(source.Output) else @import("seed.zig").Step;

pub fn steps(comptime activity: Activity, comptime kind: Memo.Kind, comptime persistent: bool) []const Step {
    if (!generated) return @import("seed.zig").steps(activity, kind, persistent);

    return comptime @import("zx").staticSequence(source, &.{
        .activity = activity,
        .phase = switch (kind) {
            .settled => .Settle,
            .demanded => .Demand,
            .planned => .Plan,
        },
    });
}
