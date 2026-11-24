const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("types.zig");
const Expression = @import("expression.zig");
const Scalar = @import("scalar.zig");
const condition = @import("../condition.zig");
const Form = Scalar.Form;

pub fn inferBinary(self: *Expression, binary: anytype, expected: ?Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    const operands = .{ binary.left, binary.right };

    return switch (binary.operator) {
        inline else => |tag| block: {
            const operator = comptime Scalar.operator(tag);

            break :block apply(operator.form, self, operands, span, if (operator.use_hint) expected else null, operator.allowed);
        },
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
    const graph = self.graph;

    return switch (form) {
        .And, .Or, .Not => result: {
            const value = try graph.scalar(.bool, span);

            _ = try self.infer(operands[0], value);

            if (form != .Not) try inferGuarded(self, operands[0], form == .And, operands[1], value);

            break :result value;
        },
        .Coalesce => result: {
            const value = try graph.payload(try self.declared(operands[0]), .optional, span);

            if (expected) |hint| try graph.expect(value, hint, span);

            _ = try self.infer(operands[1], value);

            break :result value;
        },
        .Compare, .Arithmetic, .Negative => result: {
            const value = if (form == .Arithmetic) expected orelse try graph.add(.unknown, span) else try graph.add(.unknown, span);

            if (allowed) |mask| try graph.restrict(value, mask, span);

            _ = try self.infer(operands[0], value);

            if (form != .Negative) _ = try self.infer(operands[1], value);

            break :result if (form == .Compare) try graph.scalar(.bool, span) else value;
        },
        .NegativeLiteral => graph.number(syntax.value(operands[0]).number, true, span),
        .Conditional => result: {
            const value = expected orelse try graph.add(.unknown, span);

            _ = try self.infer(operands[0], try graph.scalar(.bool, span));

            try inferGuarded(self, operands[0], true, operands[1], value);
            try inferGuarded(self, operands[0], false, operands[2], value);

            break :result value;
        },
    };
}

fn inferGuarded(self: *Expression, predicate: anytype, present: bool, operand: @TypeOf(predicate), expected: Graph.Id) zx.Error!void {
    const facts = self.nonnull.items.len;

    defer self.nonnull.shrinkRetainingCapacity(facts);

    try condition.assumeValue(self.graph.scratch, predicate, present, self.conditionScope());

    _ = try self.infer(operand, expected);
}
