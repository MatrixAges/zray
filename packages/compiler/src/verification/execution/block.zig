const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const Expressions = @import("../expressions.zig");
const terms = @import("../terms.zig");
const Session = @import("context.zig");
const walk = @import("generated_walk_symbolic_block");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
const Input = std.meta.Child(walk.Input);
const Scope = std.meta.Child(@FieldType(Input, "scope"));

const Frame = struct {
    session: Session.Frame,
    scope: *const Scope,
    evaluator: Expressions,
    outcome_view: native.SymbolicOutcome = undefined,
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn execute(conditions: *Conditions, statements: zx.ir.Block, environment: []terms.Binding, path: []const u8) zx.Error![]const u8 {
    if (statements.len == 0) return path;

    const table: *const zx.ir.ControlTable = statements.control;
    const control = zx.columns.borrow(std.meta.Child(@FieldType(Scope, "control")), table);

    const scope: Scope = .{
        .control = &control,
        .expression_payloads = conditions.program.expressions.payloads,
        .call_arguments = conditions.program.expressions.call_arguments,
    };

    const outcome = try within(conditions, &scope, environment, statements.first, statements.len, &.{
        .path = path,
        .violations = conditions.violations,
    });

    conditions.violations = outcome.violations;

    return outcome.path;
}

fn within(conditions: *Conditions, scope: *const Scope, environment: []terms.Binding, first: usize, count: usize, path: *const Session.Path) zx.Error!Session.Path {
    if (count == 0) return path.*;

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
        .path = path.path,
        .violations = path.violations,
        .first = first,
        .count = count,
    };

    const continuation = walk.executeIn(conditions.allocator, &input) catch |err| return Session.failure(err);

    if (continuation) |next_path| return .{ .path = next_path.path, .violations = next_path.violations };

    return conditions.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "verification does not yet model this statement");
}

pub fn evaluateSymbolicStatement(handle: *anyopaque, expression: ?u32) zx.Error!*const native.SymbolicOutcome {
    const frame = Frame.borrow(handle);
    const outcome: terms.Evaluation = if (expression) |id| try frame.evaluator.evaluate(@fromBackingInt(id)) else .{ .value = .{ .fields = &.{} } };

    frame.outcome_view = .{
        .safe = outcome.safe,
        .text = outcome.value.scalar,
        .fields = std.mem.sliceAsBytes(outcome.value.fields),
    };

    return &frame.outcome_view;
}

pub fn bindSymbolicStatement(handle: *anyopaque, symbol: u32, input: *const native.SymbolicOutcome, field: ?u64) void {
    const frame = Frame.borrow(handle);
    const value = terms.Value.borrow(input.text, input.fields);

    frame.evaluator.environment[symbol] = .{
        .bound = true,
        .value = if (field) |index| value.fields[@intCast(index)] else value,
    };
}

pub fn publishSymbolicStatementReturn(handle: *anyopaque, path: *const Session.Path, input: *const native.SymbolicOutcome) zx.Error![]const []const u8 {
    const frame = Frame.borrow(handle);
    const conditions = frame.session.conditions;
    const value = terms.Value.borrow(input.text, input.fields);
    const checked = try Session.apply(conditions, .Returned, path, value);

    try conditions.returns.append(conditions.allocator, .{ .path = path.path, .value = value });

    return checked.violations;
}

pub fn runSymbolicChild(allocator: std.mem.Allocator, handle: *anyopaque, body: u32, path: *const Session.Path) zx.Error!*const Session.Path {
    const frame = Frame.borrow(handle);
    const control = frame.evaluator.program.body.control;

    const outcome = try within(
        frame.session.conditions,
        frame.scope,
        frame.evaluator.environment,
        control.block_first[body],
        control.block_count[body],
        path,
    );

    const result = try allocator.create(Session.Path);

    result.* = outcome;

    return result;
}
