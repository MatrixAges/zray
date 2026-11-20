const std = @import("std");
const Bodies = @import("../bodies.zig");
const Growth = @import("../../growth.zig");
const Memo = @import("../../memo.zig");
const Slots = @import("../../slots.zig");
const Summaries = @import("../../summaries.zig");

pub const Input = struct {
    bodies: *const Bodies,
    slots: Slots,
    summaries: *Summaries,
    body: usize,
    growth: *Growth.Store,
    scratch: std.mem.Allocator,
    lasting: std.mem.Allocator,
    owner: std.mem.Allocator,
};

pub fn Output(comptime kind: Memo.Kind) type {
    return struct {
        record: Memo.Result(kind),
        changed: []const u64 = &.{},
    };
}

pub fn run(comptime kind: Memo.Kind, in: Input) std.mem.Allocator.Error!Output(kind) {
    var function = try in.bodies.analyze(in.scratch, in.lasting, in.slots, in.summaries, in.body, in.growth, false);

    return switch (kind) {
        .settled => settled: {
            const count = if (in.body < in.summaries.output.len) in.summaries.output[in.body].len else 0;
            const result = try function.settle(in.owner, count);

            break :settled .{ .record = .{ .passed = result.passed, .output = result.output }, .changed = result.changed };
        },
        .demanded => demanded: {
            const result = try function.demand(in.owner);

            break :demanded .{
                .record = .{
                    .marks = result.marks,
                    .normalized = in.growth.normalized,
                    .renewed = in.growth.renewed,
                    .grew = function.grew,
                },
                .changed = result.changed,
            };
        },
        .planned => .{ .record = Memo.Planned.fromPlan(try function.plan(in.owner)) },
    };
}
