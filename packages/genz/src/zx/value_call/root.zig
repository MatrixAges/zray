const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("seed.zig");
const policy = @import("policy.zig");
const emission = @import("emission.zig");
const conversion = @import("../state_value/conversion.zig");
const workflow = @import("generated_call_workflow");
const Sequence = @import("../../node/blocks.zig").Sequence;
pub const analysis = @import("analysis.zig");
pub const functions = analysis.functions;
pub const containsDescendant = analysis.containsDescendant;

pub fn expression(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.expression(self, id);

    return @import("../expressions/evaluate.zig").value(self, id);
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

    return lowerInvocation(self, &body, value, false, pointer);
}

fn lowerInvocation(self: *Lower, body: *Sequence, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call"), comptime borrowed: bool, pointer: bool) Lower.Error!node.ExpressionId {
    const plan = policy.invocation(self, value, borrowed, pointer);
    const function = @backingInt(value.function);
    const types = &self.program.functions;
    var argument: node.ExpressionId = undefined;
    var result: node.ExpressionId = undefined;

    inline for (comptime zx.staticSequence(workflow, if (borrowed) .Borrowed else .Value)) |step| switch (step) {
        .Evaluate => argument = switch (plan.argument) {
            .Value => try self.expr(value.argument),
            .BorrowObject => try @import("argument.zig").borrow(self, body, value.argument),
            .StackObject => try @import("borrowed_argument.zig").lower(self, body, .{ .value = try aggregate.objectValue(self, value.argument) }),
        },
        .Adapt => if (plan.input_mode != .Keep) {
            const bound = try aggregate.bind(self, body, argument);
            const mode: conversion.Mode = if (plan.input_mode == .Value) .value else .borrow;

            argument = try conversion.convert(self, body, @fromBackingInt(types.input_types[function]), bound, mode);
        },
        .Clip => if (plan.clip) {
            argument = try @import("../state_value/ownership.zig").clip(self, body, value.argument, argument);
        },
        .Invoke => result = try emission.emit(self, body, .{ .function = value.function, .value = argument, .plan = plan }),
        .Convert => {
            const output: ir.TypeId = @fromBackingInt(types.output_types[function]);

            result = switch (plan.return_mode) {
                .Borrow => try conversion.convert(self, body, output, result, .borrow),
                .Layout => try conversion.convert(self, body, output, result, .layout),
                .Pointer => try conversion.convert(self, body, output, result, .pointer),
                .Construct => try self.construct(output, result),
                .Keep => result,
            };
        },
        .Finish => result = try aggregate.finish(self, body, result),
        else => @compileError("Invalid value invocation step"),
    };

    return result;
}
