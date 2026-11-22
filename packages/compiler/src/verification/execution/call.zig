const zx = @import("zx");
const std = @import("std");
const ir = zx.ir;
const calls = @import("../calls.zig");
const Cache = @import("../call_cache.zig").Cache;
const Expression = @import("expression.zig").Frame;
const rule = @import("generated_run_symbolic_expression_call");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";

const Invocation = struct {
    frame: *Expression,
    function: ir.Function,
    description: native.SymbolicCallDescription,
    argument_id: ir.ExprId,
    key: Cache.Key = undefined,
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn runSymbolicExpressionCall(handle: *const anyopaque, target: u32, argument: u32) zx.Error!void {
    const frame = Expression.borrow(handle);
    const evaluator = frame.evaluator;
    const function = evaluator.program.functions.at(target);

    var invocation: Invocation = .{
        .frame = frame,
        .function = function,
        .description = .{
            .calls = function.expressions.call_functions,
            .target = target,
            .stores = function.stores.count(),
            .external = function.external != null,
            .depth = evaluator.call_depth,
        },
        .argument_id = @fromBackingInt(argument),
    };

    rule.executeIn(evaluator.allocator, @ptrCast(&invocation)) catch |err| return @import("context.zig").failure(err);
}

pub fn describeSymbolicCall(handle: *const anyopaque) *const native.SymbolicCallDescription {
    return &Invocation.borrow(handle).description;
}

pub fn rejectSymbolicCall(handle: *const anyopaque, message: []const u8) error{InvalidSource}!void {
    const frame = Invocation.borrow(handle).frame;

    return @errorCast(frame.evaluator.reporter.fail(.unsupported, frame.span, message));
}

pub fn evaluateSymbolicCallArgument(handle: *const anyopaque) zx.Error![]const u8 {
    const invocation = Invocation.borrow(handle);
    const result = try invocation.frame.evaluator.evaluate(invocation.argument_id);

    invocation.frame.at(.First).* = result;

    return result.safe;
}

pub fn findSymbolicCallee(handle: *const anyopaque) std.mem.Allocator.Error!bool {
    const invocation = Invocation.borrow(handle);
    const frame = invocation.frame;
    const evaluator = frame.evaluator;
    const cached = try evaluator.graph.calls.lookup(evaluator.allocator, invocation.description.target, frame.at(.First).value);

    switch (cached) {
        .hit => |result| {
            frame.at(.Result).* = result;

            return true;
        },
        .miss => |key| {
            invocation.key = key;

            return false;
        },
    }
}

pub fn evaluateSymbolicCallee(handle: *const anyopaque) zx.Error!void {
    const invocation = Invocation.borrow(handle);
    const frame = invocation.frame;

    frame.at(.Result).* = try calls.execute(frame.evaluator, invocation.function, frame.at(.First).value);
}

pub fn publishSymbolicCallee(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const invocation = Invocation.borrow(handle);
    const evaluator = invocation.frame.evaluator;

    try evaluator.graph.calls.publish(evaluator.allocator, invocation.key, invocation.frame.at(.Result).*);
}

pub fn symbolicCalleeSafety(handle: *const anyopaque) []const u8 {
    return Invocation.borrow(handle).frame.at(.Result).safe;
}

pub fn writeSymbolicCallSafety(handle: *const anyopaque, safe: []const u8) void {
    Invocation.borrow(handle).frame.at(.Result).safe = safe;
}
