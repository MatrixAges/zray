const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("seed.zig");
const policy = @import("policy.zig");
const emission = @import("emission.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
pub const analysis = @import("analysis.zig");
pub const functions = analysis.functions;
pub const containsDescendant = analysis.containsDescendant;

pub fn expression(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.expression(self, id);

    const selected = policy.dispatch(self, id);
    const value = self.program.expression(id);

    return switch (selected) {
        .Value => self.expr(id),
        .Dereference => emission.emit(self, null, .{ .value = try self.expr(id) }),
        .Capture => @import("../capture.zig").lowerValue(self, value.type_id, value.value.capture),
        .Object => aggregate.objectValue(self, id),
        .Tuple => @import("../aggregate/sequence.zig").lower(self, id, value, value.value.tuple, true),
        .Collection => @import("../collections.zig").lowerValue(self, id, try self.layoutExpr(value.type_id)),
        .Scope => @import("../scope.zig").lowerValue(self, value.value.scope),
        .Iteration => @import("../iteration.zig").lowerValue(self, id, value.value.iteration),
        .Match => @import("../match.zig").lowerValue(self, value.value.match_expr),
        .Conditional => @import("../selection/conditional.zig").lowerValue(self, value.value.conditional),
        .Invocation => invocation(self, value.value.call),
    };
}

pub fn invocation(self: *Lower, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.invocation(self, value);

    return invokeBlock(self, value, false);
}

pub fn pointerInvocation(self: *Lower, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.pointerInvocation(self, value);

    return invokeBlock(self, value, true);
}

pub fn borrowInvocation(self: *Lower, body: if (generated) *Sequence else *std.ArrayList(node.Statement), value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.borrowInvocation(self, body, value);

    return lowerInvocation(self, body, value, true, false);
}

fn invokeBlock(self: *Lower, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call"), pointer: bool) Lower.Error!node.ExpressionId {
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    const result = try lowerInvocation(self, &body, value, false, pointer);

    return aggregate.finish(self, &body, result);
}

fn lowerInvocation(self: *Lower, body: *Sequence, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call"), borrowed: bool, pointer: bool) Lower.Error!node.ExpressionId {
    const plan = policy.invocation(self, value, borrowed, pointer);
    const function = self.program.functions.at(@backingInt(value.function));

    var argument = switch (plan.argument) {
        .Value => try self.expr(value.argument),
        .BorrowObject => try @import("argument.zig").borrow(self, body, value.argument),
        .StackObject => try @import("borrowed_argument.zig").lower(self, body, .{ .value = try aggregate.objectValue(self, value.argument) }),
    };

    if (plan.input_mode != .Keep) {
        argument = try aggregate.bind(self, body, argument);
        argument = try @import("../state_value/conversion.zig").convert(self, body, function.input_type, argument, if (plan.input_mode == .Value) .value else .borrow);
    }

    if (plan.clip) argument = try @import("../state_value/ownership.zig").clip(self, body, value.argument, argument);

    const result = try emission.emit(self, body, .{ .function = value.function, .value = argument, .plan = plan });

    return switch (plan.return_mode) {
        .Borrow => @import("../state_value/conversion.zig").convert(self, body, function.output_type, result, .borrow),
        .Layout => @import("../state_value/conversion.zig").convert(self, body, function.output_type, result, .layout),
        .Pointer => @import("../state_value/conversion.zig").convert(self, body, function.output_type, result, .pointer),
        .Construct => self.construct(function.output_type, result),
        .Keep => result,
    };
}
