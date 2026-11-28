const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const aggregate = @import("../aggregate.zig");
const conversion = @import("../state_value/conversion.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Regular = @import("../regular_call/root.zig").Plan;
const Value = @import("../value_call/policy.zig").Plan;
const Operation = @FieldType(@FieldType(ir.ExpressionRow, "value"), "call");
const entry = @import("generated_lower_invocation");
const Input = std.meta.Child(entry.Input);
const Error = Lower.Error;
const CallArgument = evaluation.Api.CallArgument;

const Frame = struct {
    lowering: *Lower,
    body: *Sequence,
    operation: Operation,
    plan: union(enum) { regular: Regular, value: Value },
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
    fn inputType(self: *const Frame) ir.TypeId {
        return @fromBackingInt(self.lowering.program.functions.input_types[@backingInt(self.operation.function)]);
    }
    fn outputType(self: *const Frame) ir.TypeId {
        return @fromBackingInt(self.lowering.program.functions.output_types[@backingInt(self.operation.function)]);
    }
};

pub fn regular(lowering: *Lower, operation: Operation, plan: Regular) Error!node.ExpressionId {
    var body = lowering.builder.statementSequence(lowering.workspace);

    defer body.deinit();

    var frame: Frame = .{ .lowering = lowering, .body = &body, .operation = operation, .plan = .{ .regular = plan } };

    const argument: CallArgument = switch (plan.argument) {
        .ExternalTuple => .Tuple,
        .ScalarBorrow => .Borrow,
        .StateBorrow, .StatePointer, .Value => .Value,
    };

    const input: Input = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(&body),
        .call = @ptrCast(&frame),
        .operand = @backingInt(operation.argument),
        .operand_type = @backingInt(lowering.program.expression(operation.argument).type_id),
        .argument = argument,
        .adapt = plan.argument == .StateBorrow or plan.argument == .StatePointer,
        .clip = false,
        .stores = plan.stores,
        .convert = plan.convert_output,
        .finish = true,
        .unwrap_empty = true,
    };

    return evaluation.invokeWith(lowering, entry, &input);
}

pub fn value(lowering: *Lower, body: *Sequence, operation: Operation, borrowed: bool, pointer: bool) Error!node.ExpressionId {
    const plan = @import("../value_call/policy.zig").invocation(lowering, operation, borrowed, pointer);
    var frame: Frame = .{ .lowering = lowering, .body = body, .operation = operation, .plan = .{ .value = plan } };

    const argument: CallArgument = switch (plan.argument) {
        .BorrowObject => .Borrow,
        .StackObject => .Stack,
        .Value => .Value,
    };

    const input: Input = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(body),
        .call = @ptrCast(&frame),
        .operand = @backingInt(operation.argument),
        .operand_type = @backingInt(lowering.program.expression(operation.argument).type_id),
        .argument = argument,
        .adapt = plan.input_mode != .Keep,
        .clip = plan.clip,
        .stores = false,
        .convert = plan.return_mode != .Keep,
        .finish = !borrowed,
        .unwrap_empty = false,
    };

    return evaluation.invokeWith(lowering, entry, &input);
}

pub fn lowerCallBorrow(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../value_call/argument.zig").borrow(frame.lowering, frame.body, frame.operation.argument));
}

pub fn adaptCallArgument(handle: *anyopaque, value_id: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const bound = try aggregate.bind(frame.lowering, frame.body, @fromBackingInt(value_id));

    const mode: conversion.Mode = switch (frame.plan) {
        .regular => |plan| if (plan.argument == .StateBorrow) .borrow else .pointer,
        .value => |plan| if (plan.input_mode == .Value) .value else .borrow,
    };

    return @backingInt(try conversion.convert(frame.lowering, frame.body, frame.inputType(), bound, mode));
}

pub fn clipCallArgument(handle: *anyopaque, value_id: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../state_value/ownership.zig").clip(frame.lowering, frame.body, frame.operation.argument, @fromBackingInt(value_id)));
}

pub fn lowerCallStore(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../store.zig").adapter(frame.lowering, frame.operation));
}

pub fn emitLoweredCall(handle: *anyopaque, value_id: u32, store: ?u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const argument: node.ExpressionId = @fromBackingInt(value_id);

    return @backingInt(switch (frame.plan) {
        .regular => |plan| try @import("../regular_call/emission.zig").lower(self, .{
            .function = frame.operation.function,
            .value = argument,
            .store = if (store) |id| @fromBackingInt(id) else null,
            .io = plan.io,
            .process = plan.process,
        }),
        .value => |plan| try @import("../value_call/emission.zig").emit(self, frame.body, .{
            .function = frame.operation.function,
            .value = argument,
            .plan = plan,
        }),
    });
}

pub fn convertCallResult(handle: *anyopaque, value_id: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const output = frame.outputType();
    const result: node.ExpressionId = @fromBackingInt(value_id);

    const converted = switch (frame.plan) {
        .regular => try conversion.convert(self, frame.body, output, try aggregate.bind(self, frame.body, result), .value),
        .value => |plan| switch (plan.return_mode) {
            .Borrow => try conversion.convert(self, frame.body, output, result, .borrow),
            .Layout => try conversion.convert(self, frame.body, output, result, .layout),
            .Pointer => try conversion.convert(self, frame.body, output, result, .pointer),
            .Construct => try self.construct(output, result),
            .Keep => unreachable,
        },
    };

    return @backingInt(converted);
}
