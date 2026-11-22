const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;
const evaluation = @import("../expressions/evaluate.zig");
const analysis = @import("analysis.zig");
const rows = @import("../../node/import_rows.zig");
const lists = @import("../state_value/list.zig");
const generated = @import("generated_simd_emit");
const Error = Lower.Error;
const Output = @typeInfo(@typeInfo(@TypeOf(generated.executeValue)).@"fn".return_type.?).error_union.payload;

const Frame = struct {
    lowering: *Lower,
    plan: analysis.Plan,
    id: ir.ExprId,
    allocator: std.mem.Allocator,
    source: node.ExpressionId = undefined,
    element_type: node.ExpressionId = undefined,
    literals: []u32 = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

const Publication = struct {
    lowering: *Lower,
    output: *const Output,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, consumer: ?Consumer) Error!?node.ExpressionId {
    var plans = std.heap.ArenaAllocator.init(self.workspace);

    defer plans.deinit();

    const plan = try analysis.analyze(plans.allocator(), self.program, id, consumer);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    var frame: Frame = .{ .lowering = self, .plan = plan, .id = id, .allocator = scratch.allocator() };
    const entry = @import("generated_execute_simd");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .count = plan.expression.nodes.len,
        .accepted = plan.accepted,
        .wrap = consumer == null,
    };

    return evaluation.invokeOptional(entry, &input);
}

pub fn lowerSimdSource(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.source = try lists.expression(frame.lowering, @fromBackingInt(frame.plan.candidate.source));
}

pub fn lowerSimdElement(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.element_type = try frame.lowering.typeExpr(@fromBackingInt(frame.plan.candidate.scalar));
}

pub fn reserveSimdLiterals(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.literals = try frame.allocator.alloc(u32, frame.plan.expression.nodes.len * 2);

    @memset(frame.literals, 0);
}

pub fn simdNodeOperation(handle: *const anyopaque, index: u64) evaluation.Api.SimdOperation {
    const frame = Frame.borrow(handle);
    const operation = frame.plan.expression.nodes[@intCast(index)].operation;

    comptime @import("../../node/view.zig").compatible(@TypeOf(operation), evaluation.Api.SimdOperation);

    return @fromBackingInt(@backingInt(operation));
}

pub fn storeSimdLiteral(handle: *const anyopaque, index: u64, slot: u64) Error!void {
    const frame = Frame.borrow(handle);
    const id = frame.plan.expression.nodes[@intCast(index)].source;

    frame.literals[@intCast(slot)] = @backingInt(try frame.lowering.expr(@fromBackingInt(id)));
}

pub fn emitSimd(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const plan = frame.plan;
    const count = plan.expression.nodes.len;

    const input: std.meta.Child(generated.Input) = .{
        .nodes = plan.expression.nodes,
        .uses_element = plan.expression.uses_element,
        .source = @backingInt(frame.source),
        .element_type = @backingInt(frame.element_type),
        .vector_literals = frame.literals[0..count],
        .tail_literals = frame.literals[count..],
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };

    const output = zx.columns.invoke(generated.executeValue, frame.allocator, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const publication: Publication = .{ .lowering = self, .output = &output };
    const entry = @import("generated_publish_simd");
    const request: std.meta.Child(entry.Input) = .{ .frame = @ptrCast(&publication), .count = output.statements.len };

    try evaluation.execute(entry, &request);

    return output.root;
}

pub fn wrapSimdResult(handle: *const anyopaque, result: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const type_id = self.program.expression(frame.id).type_id;

    return @backingInt(try lists.wrap(self, type_id, @fromBackingInt(result), false));
}

pub fn appendSimdExpressions(handle: *const anyopaque) Error!void {
    const frame = Publication.borrow(handle);
    const Expressions = std.meta.Child(@FieldType(std.meta.Child(generated.Output), "expressions"));
    var expressions: Expressions = undefined;

    inline for (@typeInfo(Expressions).@"struct".field_names) |name| {
        @field(expressions, name) = @field(frame.output.expressions, name);
    }

    try append(frame.lowering, &frame.lowering.builder.nodes.expressions, &expressions);
}

pub fn appendSimdStatement(handle: *const anyopaque, index: u64) Error!void {
    const frame = Publication.borrow(handle);

    try append(frame.lowering, &frame.lowering.builder.nodes.statements, frame.output.statements[@intCast(index)]);
}

pub fn publishSimdEffects(handle: *const anyopaque) void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;

    self.serial = @intCast(frame.output.serial);
    self.uses_allocator = self.uses_allocator or frame.output.uses_allocator;
}

fn append(self: *Lower, target: anytype, source: anytype) Error!void {
    rows.append(self.allocator, target, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
