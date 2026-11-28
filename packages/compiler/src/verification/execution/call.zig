const zx = @import("zx");
const std = @import("std");
const calls = @import("../calls.zig");
const Expression = @import("expression.zig").Frame;
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
const rule = @import("generated_run_symbolic_expression_call");

pub fn runSymbolicExpressionCall(handle: *anyopaque, target: u32, argument: u32) zx.Error!*const native.CallSafety {
    const frame = Expression.borrow(handle);
    const evaluator = frame.evaluator;
    const function = evaluator.program.functions.at(target);

    const input: std.meta.Child(rule.Input) = .{
        .frame = @ptrCast(handle),
        .argument = argument,
        .calls = function.expressions.call_functions,
        .target = target,
        .stores = function.stores.count(),
        .external = function.external != null,
        .depth = evaluator.call_depth,
    };

    var result_arena = std.heap.ArenaAllocator.init(evaluator.allocator);
    var buffer: [1024]u8 = undefined;
    var result_memory = std.heap.BufferFirstAllocator.init(&buffer, result_arena.allocator());

    defer result_arena.deinit();

    const outcome = rule.executeIn(result_memory.allocator(), &input) catch |err| return @import("context.zig").failure(err);

    if (outcome.diagnostic) |message| return evaluator.reporter.fail(.unsupported, frame.span, message);

    const safety = outcome.safety.?;

    frame.call_safety = .{ .argument = safety.argument, .callee = safety.callee };

    return &frame.call_safety;
}

pub fn findSymbolicCallee(allocator: std.mem.Allocator, handle: *anyopaque, target: u32) std.mem.Allocator.Error!*const native.CallProbe {
    const frame = Expression.borrow(handle);
    const evaluator = frame.evaluator;
    const cached = try evaluator.graph.calls.lookup(evaluator.allocator, target, frame.at(.First).value);
    const probe = try allocator.create(native.CallProbe);

    switch (cached) {
        .hit => |result| {
            frame.at(.Result).* = result;

            probe.* = .{ .safe = result.safe, .key = null };
        },
        .miss => |key| {
            const stored = try allocator.create(native.CallKey);

            stored.* = .{ .target = key.target, .start = key.start, .length = key.length, .digest = key.digest };
            probe.* = .{ .safe = null, .key = stored };
        },
    }

    return probe;
}

pub fn evaluateSymbolicCallee(handle: *anyopaque, target: u32) zx.Error![]const u8 {
    const frame = Expression.borrow(handle);
    const evaluator = frame.evaluator;
    const result = try calls.execute(evaluator, evaluator.program.functions.at(target), frame.at(.First).value);

    frame.at(.Result).* = result;

    return result.safe;
}

pub fn publishSymbolicCallee(handle: *anyopaque, probe: *const native.CallProbe) std.mem.Allocator.Error!void {
    const frame = Expression.borrow(handle);
    const evaluator = frame.evaluator;
    const key = probe.key.?;

    try evaluator.graph.calls.publish(evaluator.allocator, .{
        .target = key.target,
        .start = @intCast(key.start),
        .length = @intCast(key.length),
        .digest = key.digest,
    }, frame.at(.Result).*);
}
