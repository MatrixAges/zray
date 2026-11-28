const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Expressions = @import("../expressions.zig");
const Evaluation = @import("../terms.zig").Evaluation;
const Value = @import("../terms.zig").Value;
const rule = @import("generated_walk_symbolic_expression");
const call = @import("call.zig");
const Input = std.meta.Child(rule.Input);
pub const Columns = std.meta.Child(@FieldType(Input, "columns"));
pub const Types = std.meta.Child(@FieldType(Input, "types"));
pub const Environment = @FieldType(Input, "environment");
pub const Binding = std.meta.Elem(Environment);
pub const BoundValue = @typeInfo(Binding).optional.child;
const Store = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Exchange = std.meta.Child(Store);
const Result = std.meta.Child(@FieldType(Exchange, "result"));

const Host = struct {
    evaluator: *Expressions,
    target: ir.TypeId,
    span: zx.Span,
    temporary: std.mem.Allocator,
    store_0: *Store,
    pub fn commit(host: *Host, pending: anytype) zx.Error!void {
        const operation = pending.store_0 orelse return;
        const request = operation.request.?;
        const evaluator = host.evaluator;
        const allocator = host.temporary;
        const exchange = try allocator.create(Exchange);
        const result = try allocator.create(Result);
        result.* = operation.result.*;
        result.key = null;

        switch (request.step) {
            .Evaluate => {
                const value = try evaluator.evaluate(@fromBackingInt(request.row.?));

                result.value = try value.view(@TypeOf(result.value), allocator);
            },
            .Bind => result.text = try evaluator.boolean(request.text.?, host.span),
            .Select => {
                const yes = Evaluation.fromView(request.yes.?);
                const no = Evaluation.fromView(request.no.?);
                const selected = try evaluator.graph.select(evaluator.program, host.target, request.text.?, yes.value, no.value, host.span);
                result.value = try (Evaluation{ .value = selected }).view(@TypeOf(result.value), allocator);
            },
            .Retain => {
                const value = try evaluator.retainAt(host.target, host.span, .{
                    .value = Evaluation.fromView(request.value.?).value,
                    .safe = request.text.?,
                });

                result.value = try value.view(@TypeOf(result.value), allocator);
            },
            .DescribeCall => {
                const description = try allocator.create(std.meta.Child(@TypeOf(result.description)));

                description.* = call.describeCallee(evaluator, request.row.?, @TypeOf(description.*));
                result.description = description;
            },
            .FindCall => try call.probeCallee(evaluator, request.row.?, Evaluation.fromView(request.value.?).value, result, allocator),
            .ExecuteCall => {
                const value = try call.executeCallee(evaluator, request.row.?, Evaluation.fromView(request.value.?).value);

                result.value = try value.view(@TypeOf(result.value), allocator);
            },
            .PublishCall => try call.publishCallee(evaluator, request.key.?, Evaluation.fromView(request.value.?)),
        }

        exchange.* = .{ .request = null, .result = result };
        host.store_0.* = exchange;
    }
};

pub fn execute(evaluator: *Expressions, id: ir.ExprId, target: ir.TypeId, span: zx.Span) zx.Error!Evaluation {
    const depth = evaluator.depth;
    evaluator.depth += 1;
    defer evaluator.depth = depth;

    if (evaluator.columns == null) {
        const expressions: *const ir.ExpressionTable = &evaluator.program.expressions;

        evaluator.columns = zx.columns.borrow(Columns, expressions);
    }

    if (evaluator.types == null) {
        const types: *const zx.ir.TypeTable = &evaluator.program.types;

        evaluator.types = zx.columns.borrow(Types, types);
    }

    const layout = Value.layout(std.meta.Child(@FieldType(Input, "layout")));

    const input: Input = .{
        .columns = &evaluator.columns.?,
        .types = &evaluator.types.?,
        .id = @backingInt(id),
        .depth = depth,
        .environment = evaluator.environment,
        .layout = &layout,
    };

    var effects = zx.Arena.initSmall(evaluator.scratch.child);
    var buffer: [2048]u8 = undefined;
    var temporary = std.heap.BufferFirstAllocator.init(&buffer, effects.allocator());

    defer effects.deinit();

    var store: Store = &.{
        .request = null,
        .result = &.{
            .text = "",
            .value = &.{ .text = null, .fields = &.{}, .safe = "true" },
            .key = null,
            .description = &.{ .target = 0, .calls = &.{}, .stores = 0, .external = false, .depth = 0 },
        },
    };

    var host: Host = .{
        .evaluator = evaluator,
        .target = target,
        .span = span,
        .temporary = temporary.allocator(),
        .store_0 = &store,
    };

    const outcome = rule.executeIn(evaluator.allocator, &input, &host) catch |err| return @import("context.zig").failure(err);

    if (outcome.diagnostic) |message| return evaluator.reporter.fail(.unsupported, span, message);
    if (outcome.contract) |message| return evaluator.reporter.fail(.contract, span, message);

    if (outcome.fields) |rows| {
        const fields = try evaluator.allocator.alloc(Value, rows.len);

        for (rows) |field| fields[field.index] = Value.borrow(field.text, field.fields);

        return .{ .value = .{ .fields = fields }, .safe = outcome.safe orelse "true" };
    }

    if (outcome.value) |source| {
        var evaluated = Evaluation.fromView(source);

        if (outcome.safe) |safe| evaluated.safe = safe;

        return evaluated;
    }

    return .{ .value = .{ .scalar = outcome.scalar }, .safe = outcome.safe orelse "true" };
}
