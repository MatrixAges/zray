const Plan = @import("../root.zig").Plan;
const Level = @import("../level.zig").Level;

pub const Phase = if (@import("genz_options").generated_analysis)
    @FieldType(@import("std").meta.Child(@import("generated_uniqueness_prepare_round").Input), "phase")

else
    enum { Start, Replay, Settle, Demand, Plan, Commit, Done };

pub const Outcome = struct { exhausted: bool = false, grew: bool = false };
pub const Visit = union(enum) { done, exhausted, body: usize };

pub const Window = struct {
    first: []const u64,
    second: []const u64 = &.{},
    pub fn at(self: Window, position: usize) u64 {
        return if (position < self.first.len) self.first[position] else self.second[position - self.first.len];
    }
};

pub const Settlement = struct {
    active: []const bool,
    outputs: [][]Level,
    dirty: []bool,
    changed: []const u64,
    callers: []const u64,
    body: usize,
    levels: []const Level,
};

pub const Frame = struct {
    active: []const bool,
    outputs: [][]Level,
    dirty: []bool,
    callers: []const []const u64,
    plans: ?PlanTarget = null,
};

pub const PlanTarget = struct {
    functions: []Plan,
    entry: *Plan,
};

pub const Feedback = struct {
    body: usize,
    changed: []const u64,
    levels: []const Level = &.{},
    grew: bool = false,
    plan: ?[]const u8 = null,
};

pub const Claim = struct { visit: Visit, pending: Window, grew: bool, prefetch: bool };
