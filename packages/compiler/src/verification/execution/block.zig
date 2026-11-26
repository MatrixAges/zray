const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const Expressions = @import("../expressions.zig");
const terms = @import("../terms.zig");
const Session = @import("context.zig");
const walk = @import("generated_walk_symbolic_block");
const parallel = @import("generated_run_symbolic_parallel");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
const Input = std.meta.Child(walk.Input);
const Scope = std.meta.Child(@FieldType(Input, "scope"));
const Parallel = std.meta.Child(parallel.Input);

const Frame = struct {
    session: Session.Frame,
    scope: *const Scope,
    evaluator: Expressions,
    outcome: terms.Evaluation = undefined,
    outcome_view: native.SymbolicOutcome = undefined,
    completed: []terms.Evaluation = &.{},
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn execute(conditions: *Conditions, statements: zx.ir.Block, environment: []?terms.Value, path: []const u8) zx.Error![]const u8 {
    if (statements.len == 0) return path;

    const control = zx.columns.borrow(std.meta.Child(@FieldType(Scope, "control")), statements.control);

    const scope: Scope = .{
        .control = &control,
        .expression_payloads = conditions.program.expressions.payloads,
        .call_arguments = conditions.program.expressions.call_arguments,
    };

    return within(conditions, &scope, environment, statements.first, statements.len, path);
}

fn within(conditions: *Conditions, scope: *const Scope, environment: []?terms.Value, first: usize, count: usize, path: []const u8) zx.Error![]const u8 {
    if (count == 0) return path;

    const checkpoint = conditions.scratch.checkpoint();

    defer conditions.scratch.rewindRetainingCapacity(checkpoint);

    var frame: Frame = .{
        .session = .{ .conditions = conditions, .value = null },
        .scope = scope,
        .evaluator = .{
            .allocator = conditions.allocator,
            .scratch = conditions.scratch,
            .program = conditions.program,
            .environment = environment,
            .graph = conditions.graph.?,
            .reporter = conditions.reporter,
            .call_depth = conditions.call_depth,
        },
    };

    const input: Input = .{
        .block = @ptrCast(&frame),
        .session = @ptrCast(&frame.session),
        .scope = scope,
        .path = path,
        .first = first,
        .count = count,
    };

    return walk.executeIn(conditions.allocator, &input) catch |err| return Session.failure(err);
}

pub fn evaluateSymbolicStatement(handle: *anyopaque, expression: ?u32) zx.Error!*const native.SymbolicOutcome {
    const frame = Frame.borrow(handle);
    const outcome: terms.Evaluation = if (expression) |id| try frame.evaluator.evaluate(@fromBackingInt(id)) else .{ .value = .{ .fields = &.{} } };
    frame.outcome = outcome;

    frame.outcome_view = .{
        .safe = outcome.safe,
        .text = if (outcome.value == .scalar) outcome.value.scalar else null,
    };

    return &frame.outcome_view;
}

pub fn bindSymbolicStatement(handle: *anyopaque, symbol: u32) void {
    const frame = Frame.borrow(handle);

    frame.evaluator.environment[symbol] = frame.outcome.value;
}

pub fn bindSymbolicStatementField(handle: *anyopaque, symbol: u32, field: u64) void {
    const frame = Frame.borrow(handle);

    frame.evaluator.environment[symbol] = frame.outcome.value.fields[@intCast(field)];
}

pub fn publishSymbolicStatementReturn(handle: *anyopaque, path: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const conditions = frame.session.conditions;
    const value = frame.outcome.value;

    try conditions.postconditions(path, value);
    try conditions.returns.append(conditions.allocator, .{ .path = path, .value = value });
}

pub fn runSymbolicChild(handle: *anyopaque, body: u32, path: []const u8) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);
    const control = frame.evaluator.program.body.control;

    return within(
        frame.session.conditions,
        frame.scope,
        frame.evaluator.environment,
        control.block_first[body],
        control.block_count[body],
        path,
    );
}

pub fn runSymbolicParallel(handle: *anyopaque, payload: u64, path: []const u8) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);
    const allocator = frame.evaluator.allocator;

    defer {
        allocator.free(frame.completed);

        frame.completed = &.{};
    }

    const input: Parallel = .{
        .block = @ptrCast(frame),
        .session = @ptrCast(&frame.session),
        .scope = frame.scope,
        .path = path,
        .payload = payload,
    };

    return parallel.executeIn(allocator, &input) catch |err| return Session.failure(err);
}

pub fn reserveSymbolicParallel(handle: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.completed = try frame.evaluator.allocator.alloc(terms.Evaluation, @intCast(count));
}

pub fn saveSymbolicParallel(handle: *anyopaque, index: u64) void {
    const frame = Frame.borrow(handle);

    frame.completed[@intCast(index)] = frame.outcome;
}

pub fn bindSymbolicParallel(handle: *anyopaque, index: u64, symbol: u32) void {
    const frame = Frame.borrow(handle);

    frame.evaluator.environment[symbol] = frame.completed[@intCast(index)].value;
}

pub fn rejectSymbolicStatement(handle: *anyopaque) error{InvalidSource}!?[]const u8 {
    const reporter = Frame.borrow(handle).evaluator.reporter;

    return @errorCast(reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "verification does not yet model this statement"));
}
