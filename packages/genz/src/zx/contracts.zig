const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const generated = @import("genz_options").generated_analysis;
const scope = @import("functions/scope.zig");
const evaluation = @import("expressions/evaluate.zig");
const Sequence = @import("../node/blocks.zig").Sequence;
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    statements: Sequence,
    predicate: Lower = undefined,
    expression: zx.ir.ExprId = undefined,
    value: node.ExpressionId = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn preconditions(self: *Lower) Error!node.Block {
    if (!generated) return @import("contracts/seed.zig").lower(self);

    const kinds = self.program.contracts.kinds;

    if (kinds.len == 0) return .{ .start = @intCast(self.builder.nodes.statements.tags.items.len), .len = 0 };

    const entry = @import("generated_lower_preconditions");
    const Input = std.meta.Child(entry.Input);
    var frame: Frame = .{ .lowering = self, .statements = self.builder.statementSequence(self.workspace) };

    defer frame.statements.deinit();

    const input: Input = .{ .frame = @ptrCast(&frame), .kinds = zx.columns.slice(@FieldType(Input, "kinds"), kinds) };

    try evaluation.execute(entry, &input);

    return self.builder.finishStatements(&frame.statements);
}

pub fn openPreconditionScope(handle: *anyopaque, index: u64) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const contracts = &self.program.contracts;
    const row: usize = @intCast(index);
    const predicate = &frame.predicate;

    predicate.* = scope.inherit(self, .Predicate);

    scope.installPredicate(&predicate.program, contracts, row);

    try predicate.refreshEntry();
    try scope.reserve(predicate, self.allocator, .Predicate);

    frame.expression = @fromBackingInt(contracts.predicates[row]);
}

pub fn evaluatePrecondition(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.value = try frame.predicate.expr(frame.expression);
}

pub fn emitPrecondition(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    try @import("intrinsics/guard.zig").precondition(frame.lowering, &frame.statements, frame.value);
}

pub fn publishPreconditionScope(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    scope.publish(frame.lowering, &frame.predicate, .Predicate);
}
