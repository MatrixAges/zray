const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
pub const generated = @import("genz_options").generated_analysis;

pub const Observation = struct {
    evaluation: []const ir.ExprId,
    prior: []const u64,
    references: []const node.ExpressionId,
};

pub fn retire(self: *Lower, scratch: std.mem.Allocator, body: anytype, observation: Observation) Lower.Error!void {
    _ = scratch;

    for (observation.evaluation, observation.prior, observation.references) |item, prior, reference| {
        if (self.cache_reads[@backingInt(item)] == prior) try body.append(self.allocator, .{ .discard = reference });
    }
}
