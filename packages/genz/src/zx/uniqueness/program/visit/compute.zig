const std = @import("std");
const Bodies = @import("../bodies.zig");
const Function = @import("../../function.zig");
const Growth = @import("../../growth.zig");
const Memo = @import("../../memo.zig");
const Slots = @import("../../slots.zig");
const Summaries = @import("../../summaries.zig");
const generated = @import("genz_options").generated_analysis;

pub const Input = struct {
    bodies: *const Bodies,
    slots: Slots,
    summaries: *Summaries,
    body: usize,
    growth: ?*Growth.Store,
    scratch: std.mem.Allocator,
    lasting: std.mem.Allocator,
    owner: std.mem.Allocator,
    restored_growth: bool = false,
};

pub fn Output(comptime kind: Memo.Kind, comptime deferred: bool) type {
    return struct {
        record: Memo.Result(kind),
        changed: if (deferred) void else []const u64 = if (deferred) {} else &.{},
        reads: if (deferred) []const Function.Read else void = if (deferred) &.{} else {},
    };
}

pub fn run(comptime kind: Memo.Kind, comptime deferred: bool, in: Input) std.mem.Allocator.Error!Output(kind, deferred) {
    if (generated) return @import("analysis.zig").run(kind, deferred, in);

    var function = try in.bodies.analyze(in.scratch, in.lasting, in.slots, in.summaries, in.body, in.growth, deferred);
    function.deferred = deferred;

    return switch (kind) {
        .settled => settled: {
            const count = if (in.body < in.summaries.output.len) in.summaries.output[in.body].len else 0;
            const result = try function.settle(in.owner, count);

            break :settled .{
                .record = .{ .passed = result.passed, .output = result.output },
                .changed = if (deferred) {} else result.changed,
                .reads = if (deferred) result.reads else {},
            };
        },
        .demanded => demanded: {
            const result = try function.demand(in.owner);
            const growth = try in.growth.?.capture(in.owner);

            break :demanded .{
                .record = .{
                    .marks = result.marks,
                    .normalized = growth.normalized,
                    .renewed = growth.renewed,
                    .grew = function.grew,
                },
                .changed = if (deferred) {} else result.changed,
                .reads = if (deferred) result.reads else {},
            };
        },
        .planned => .{ .record = Memo.Planned.fromPlan(try function.plan(in.owner)) },
    };
}
