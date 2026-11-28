const std = @import("std");
const zx = @import("zx");
const calls = @import("../calls.zig");
const Expressions = @import("../expressions.zig");
const terms = @import("../terms.zig");

pub fn describeCallee(evaluator: *const Expressions, target: u32, comptime Description: type) Description {
    const function = evaluator.program.functions.at(target);

    return .{
        .calls = function.expressions.call_functions,
        .target = target,
        .stores = function.stores.count(),
        .external = function.external != null,
        .depth = evaluator.call_depth,
    };
}

pub fn probeCallee(evaluator: *Expressions, target: u32, argument: terms.Value, result: anytype, allocator: std.mem.Allocator) zx.Error!void {
    const cached = try evaluator.graph.calls.lookup(evaluator.allocator, target, argument);

    switch (cached) {
        .hit => |value| result.value = try value.view(@TypeOf(result.value), allocator),
        .miss => |key| {
            const Key = @typeInfo(@TypeOf(result.key)).optional.child;
            const stored = try allocator.create(std.meta.Child(Key));
            stored.* = .{ .target = key.target, .start = key.start, .length = key.length, .digest = key.digest };
            result.key = stored;
        },
    }
}

pub fn executeCallee(evaluator: *Expressions, target: u32, argument: terms.Value) zx.Error!terms.Evaluation {
    return calls.execute(evaluator, evaluator.program.functions.at(target), argument);
}

pub fn publishCallee(evaluator: *Expressions, key: anytype, value: terms.Evaluation) zx.Error!void {
    try evaluator.graph.calls.publish(evaluator.allocator, .{
        .target = key.target,
        .start = @intCast(key.start),
        .length = @intCast(key.length),
        .digest = key.digest,
    }, value);
}
