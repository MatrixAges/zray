const ir = @import("zx").ir;
const Level = @import("../level.zig").Level;

pub const Event = enum {
    start,
    settled,
    exhausted,
    demand_grew,
    demand_stable,
};

pub const Phase = enum { settled, demanded, planned };
pub const Step = struct { phase: Phase, budget: u64 };
pub const Visit = union(enum) { done, exhausted, body: usize };

pub const Settlement = struct {
    program: *const ir.Program,
    outputs: [][]Level,
    dirty: []bool,
    changed: []const u64,
    callers: []const u64,
    body: usize,
    levels: []const Level,
};
