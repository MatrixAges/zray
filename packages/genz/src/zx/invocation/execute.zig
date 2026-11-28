const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const evaluation = @import("../expressions/evaluate.zig");
const Regular = @import("../regular_call/root.zig").Plan;
const Operation = @FieldType(@FieldType(ir.ExpressionRow, "value"), "call");
const entry = @import("generated_lower_invocation");
const Input = std.meta.Child(entry.Input);
const Error = Lower.Error;
const Api = evaluation.Api;
const Target = std.meta.Child(@FieldType(Input, "target"));

pub fn regular(lowering: *Lower, operation: Operation, plan: Regular) Error!node.ExpressionId {
    var body = lowering.builder.statementSequence(lowering.workspace);

    defer body.deinit();

    const argument: Api.CallArgument = switch (plan.argument) {
        .ExternalTuple => .Tuple,
        .ScalarBorrow => .Borrow,
        .StateBorrow, .StatePointer, .Value => .Value,
    };

    const function_id = @backingInt(operation.function);

    const input: Input = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(&body),
        .target = &.{ .function_id = function_id, .io = plan.io, .process = plan.process, .value = null },
        .operand = @backingInt(operation.argument),
        .operand_type = @backingInt(lowering.program.expression(operation.argument).type_id),
        .input_type = lowering.program.functions.input_types[function_id],
        .output_type = lowering.program.functions.output_types[function_id],
        .argument = argument,
        .adapt = switch (plan.argument) {
            .StateBorrow => .Borrow,
            .StatePointer => .Pointer,
            else => null,
        },
        .clip = false,
        .mapping = if (plan.stores) operation.stores else null,
        .convert = if (plan.convert_output) .Value else null,
        .finish = true,
        .unwrap_empty = true,
    };

    return evaluation.invokeWith(lowering, entry, &input);
}

pub fn value(lowering: *Lower, body: *Sequence, operation: Operation, borrowed: bool, pointer: bool) Error!node.ExpressionId {
    const plan = @import("../value_call/policy.zig").invocation(lowering, operation, borrowed, pointer);
    const function_id = @backingInt(operation.function);

    const argument: Api.CallArgument = switch (plan.argument) {
        .BorrowObject => .Borrow,
        .StackObject => .Stack,
        .Value => .Value,
    };

    const target: Target = .{
        .function_id = function_id,
        .io = false,
        .process = false,
        .value = &.{
            .regular = plan.variant == .Regular,
            .result = @intCast(@backingInt(plan.result)),
            .legacy = plan.legacy,
            .legacy_deref = plan.legacy_deref,
        },
    };

    const input: Input = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(body),
        .target = &target,
        .operand = @backingInt(operation.argument),
        .operand_type = @backingInt(lowering.program.expression(operation.argument).type_id),
        .input_type = lowering.program.functions.input_types[function_id],
        .output_type = lowering.program.functions.output_types[function_id],
        .argument = argument,
        .adapt = switch (plan.input_mode) {
            .Keep => null,
            .Borrow => .Borrow,
            .Value => .Value,
        },
        .clip = plan.clip,
        .mapping = null,
        .convert = switch (plan.return_mode) {
            .Keep => null,
            .Borrow => .Borrow,
            .Layout => .Layout,
            .Pointer => .Pointer,
            .Construct => .Construct,
        },
        .finish = !borrowed,
        .unwrap_empty = false,
    };

    return evaluation.invokeWith(lowering, entry, &input);
}

pub fn lowerCallStore(frame: *anyopaque, function_id: u32, operand: u32, mapping: []const u32) Error!u32 {
    const operation: Operation = .{
        .function = @fromBackingInt(function_id),
        .argument = @fromBackingInt(operand),
        .stores = mapping,
    };

    return @backingInt(try @import("../store.zig").adapter(evaluation.borrow(frame), operation));
}

pub fn emitLoweredCall(frame: *anyopaque, body: *anyopaque, target: *const @import("execution_abi").layouts.@"zig:ast_rows".CallTarget, value_id: u32, store: ?u32) Error!u32 {
    const self = evaluation.borrow(frame);
    const function: ir.FunctionId = @fromBackingInt(target.function_id);
    const argument: node.ExpressionId = @fromBackingInt(value_id);

    if (target.value) |plan| {
        return @backingInt(try @import("../value_call/emission.zig").emit(self, @ptrCast(@alignCast(body)), .{
            .function = function,
            .value = argument,
            .plan = plan,
        }));
    }

    return @backingInt(try @import("../regular_call/emission.zig").lower(self, .{
        .function = function,
        .value = argument,
        .store = if (store) |id| @fromBackingInt(id) else null,
        .io = target.io,
        .process = target.process,
    }));
}
