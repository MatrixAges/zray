const zx = @import("zx");
const std = @import("std");
const ir = zx.ir;
const calls = @import("../calls.zig");
const Cache = @import("../call_cache.zig").Cache;
const Expression = @import("expression.zig").Frame;
const rule = @import("generated_run_symbolic_expression_call");

const Invocation = struct {
    frame: *Expression,
    function: ir.Function,
    target: u32,
    argument_id: ir.ExprId,
    key: Cache.Key = undefined,
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn runSymbolicExpressionCall(handle: *anyopaque, target: u32, argument: u32) zx.Error![]const u8 {
    const frame = Expression.borrow(handle);
    const evaluator = frame.evaluator;
    const function = evaluator.program.functions.at(target);

    var invocation: Invocation = .{
        .frame = frame,
        .function = function,
        .target = target,
        .argument_id = @fromBackingInt(argument),
    };

    const input: std.meta.Child(rule.Input) = .{
        .frame = @ptrCast(frame),
        .call = @ptrCast(&invocation),
        .calls = function.expressions.call_functions,
        .target = target,
        .stores = function.stores.count(),
        .external = function.external != null,
        .depth = evaluator.call_depth,
    };

    return rule.executeIn(evaluator.allocator, &input) catch |err| return @import("context.zig").failure(err);
}

pub fn evaluateSymbolicCallArgument(handle: *anyopaque) zx.Error![]const u8 {
    const invocation = Invocation.borrow(handle);
    const result = try invocation.frame.evaluator.evaluate(invocation.argument_id);

    invocation.frame.at(.First).* = result;

    return result.safe;
}

pub fn findSymbolicCallee(handle: *anyopaque) std.mem.Allocator.Error!?[]const u8 {
    const invocation = Invocation.borrow(handle);
    const frame = invocation.frame;
    const evaluator = frame.evaluator;
    const cached = try evaluator.graph.calls.lookup(evaluator.allocator, invocation.target, frame.at(.First).value);

    switch (cached) {
        .hit => |result| {
            frame.at(.Result).* = result;

            return result.safe;
        },
        .miss => |key| {
            invocation.key = key;

            return null;
        },
    }
}

pub fn evaluateSymbolicCallee(handle: *anyopaque) zx.Error![]const u8 {
    const invocation = Invocation.borrow(handle);
    const frame = invocation.frame;
    const result = try calls.execute(frame.evaluator, invocation.function, frame.at(.First).value);

    frame.at(.Result).* = result;

    return result.safe;
}

pub fn publishSymbolicCallee(handle: *anyopaque) std.mem.Allocator.Error!void {
    const invocation = Invocation.borrow(handle);
    const evaluator = invocation.frame.evaluator;

    try evaluator.graph.calls.publish(evaluator.allocator, invocation.key, invocation.frame.at(.Result).*);
}
