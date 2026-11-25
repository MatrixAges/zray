const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const failure = @import("../construction/publication.zig").failure;
pub const generated = @import("genz_options").generated_analysis;

pub const Observation = struct {
    evaluation: []const ir.ExprId,
    prior: []const u64,
    references: []const node.ExpressionId,
};

pub fn bind(self: *Lower, scratch: std.mem.Allocator, body: *Sequence, names: []const []const u8, values: []const u32) Lower.Error!void {
    const entry = @import("generated_aggregate_operand_bindings");

    const input: std.meta.Child(entry.Input) = .{
        .writer = @ptrCast(self),
        .sequence = @ptrCast(body),
        .names = names,
        .values = values,
    };

    try emit(scratch, entry, &input);
}

pub fn retire(self: *Lower, scratch: std.mem.Allocator, body: anytype, observation: Observation) Lower.Error!void {
    if (!generated) {
        for (observation.evaluation, observation.prior, observation.references) |item, prior, reference| {
            if (self.cache_reads[@backingInt(item)] == prior) try body.append(self.allocator, .{ .discard = reference });
        }

        return;
    }

    const entry = @import("generated_aggregate_operand_retirement");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .writer = @ptrCast(self),
        .sequence = @ptrCast(body),
        .evaluation = view.slice(@FieldType(Input, "evaluation"), observation.evaluation),
        .prior = observation.prior,
        .dense = self.cache_reads,
        .references = view.slice(@FieldType(Input, "references"), observation.references),
    };

    try emit(scratch, entry, &input);
}

fn emit(scratch: std.mem.Allocator, comptime entry: type, input: entry.Input) Lower.Error!void {
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch);

    entry.executeIn(memory.allocator(), input) catch |err| return failure(err);
}
