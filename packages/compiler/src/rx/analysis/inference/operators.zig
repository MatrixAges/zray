const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("types.zig");
const Expression = @import("expression.zig");
const Scalar = @import("scalar.zig");
const condition = @import("../condition.zig");
const enabled = @import("rx_options").generated_graph;
const generated = if (enabled) @import("generated_rx_operator_constraints") else void;
const seed = @import("operators/seed.zig");
const Form = if (enabled) generated.Input else seed.Form;
const Step = if (enabled) std.meta.Child(generated.Output) else seed.Step;
const plan_capacity = 5;

pub fn inferBinary(self: *Expression, binary: anytype, expected: ?Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    const operator = Scalar.operator(binary.operator);
    const operands = .{ binary.left, binary.right };

    return switch (operator.route) {
        .and_value => apply(.And, self, operands, span, null, null),
        .or_value => apply(.Or, self, operands, span, null, null),
        .coalesce => apply(.Coalesce, self, operands, span, expected, null),
        .compare => apply(.Compare, self, operands, span, null, operator.allowed),
        .arithmetic => apply(.Arithmetic, self, operands, span, expected, operator.allowed),
    };
}

pub fn inferUnary(self: *Expression, unary: anytype, span: zx.Span) zx.Error!Graph.Id {
    const operands = .{unary.operand};

    if (unary.operator == .not) return apply(.Not, self, operands, span, null, null);
    if (syntax.value(unary.operand) == .number) return apply(.NegativeLiteral, self, operands, span, null, null);

    return apply(.Negative, self, operands, span, null, Scalar.domain(.signed));
}

pub fn inferConditional(self: *Expression, branch: anytype, expected: ?Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    return apply(.Conditional, self, .{ branch.condition, branch.yes, branch.no }, span, expected, null);
}

fn apply(comptime form: Form, self: *Expression, operands: anytype, span: zx.Span, expected: ?Graph.Id, allowed: ?Scalar.Mask) zx.Error!Graph.Id {
    const steps = comptime plan(form);
    const graph = self.graph;
    var result: Graph.Id = undefined;

    inline for (steps) |step| {
        switch (step) {
            .Done => {},
            .Boolean => result = try graph.scalar(.bool, span),
            .Unknown => result = try graph.add(.unknown, span),
            .Expected => result = expected orelse try graph.add(.unknown, span),
            .NegativeLiteral => result = try graph.number(syntax.value(operands[0]).number, true, span),
            .Restrict => if (allowed) |mask| try graph.restrict(result, mask, span),
            .DeclareLeft => result = try self.declared(operands[0]),
            .OptionalPayload => result = try graph.payload(result, .optional, span),
            .ExpectResult => if (expected) |hint| try graph.expect(result, hint, span),
            .InferLeft => _ = try self.infer(operands[0], result),
            .InferRight => _ = try self.infer(operands[1], result),
            .InferCondition => _ = try self.infer(operands[0], try graph.scalar(.bool, span)),
            .InferRightIfTrue, .InferRightIfFalse => try inferGuarded(self, operands[0], step == .InferRightIfTrue, operands[1], result),
            .InferThirdIfFalse => try inferGuarded(self, operands[0], false, operands[2], result),
        }
    }

    return result;
}

fn inferGuarded(self: *Expression, predicate: anytype, present: bool, operand: @TypeOf(predicate), expected: Graph.Id) zx.Error!void {
    const facts = self.nonnull.items.len;

    defer self.nonnull.shrinkRetainingCapacity(facts);

    try condition.assumeValue(self.graph.scratch, predicate, present, self.conditionScope());

    _ = try self.infer(operand, expected);
}

fn plan(comptime form: Form) [plan_capacity]Step {
    if (!enabled) return seed.plan(form);

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = generated.executeValue(scratch.allocator(), form) catch unreachable;
    var steps: [plan_capacity]Step = @splat(.Done);

    @memcpy(steps[0..sequence.len], sequence);

    return steps;
}
