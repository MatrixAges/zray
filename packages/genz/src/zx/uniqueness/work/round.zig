const ir = @import("zx").ir;
const Level = @import("../level.zig").Level;
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
