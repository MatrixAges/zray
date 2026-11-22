const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const seed = @import("seed.zig");
const value = @import("../value_call/root.zig");
const Operation = seed.Operation;
const Error = Lower.Error;

pub const Plan = struct {
    argument: evaluation.Api.RegularCallArgument,
    convert_output: bool,
    stores: bool,
    io: bool,
    process: bool,
};

const Frame = struct {
    lowering: *Lower,
    invocation: Operation,
    fn borrow(handle: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, invocation: Operation) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return seed.lower(self, invocation);

    const entry = @import("generated_lower_planned_call");
    const Request = std.meta.Child(entry.Input);
    const Input = std.meta.Child(@FieldType(Request, "source"));
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const Cache = std.meta.Child(@FieldType(Input, "cache"));
    const index = @backingInt(invocation.function);
    const function = self.program.functions.at(index);
    const types: Types = .{ .kinds = self.program.types.kinds, .first = self.program.types.first };

    const cache: Cache = .{
        .count = self.cache.state.count,
        .metadata = self.cache.state.metadata.items,
        .keys = self.cache.state.keys.items,
        .key = @backingInt(invocation.argument),
    };

    const source: Input = .{
        .types = &types,
        .cache = &cache,
        .input = @backingInt(function.input_type),
        .output = @backingInt(function.output_type),
        .input_query = zx.columns.view(@FieldType(Input, "input_query"), self.state_plan.queries[@backingInt(function.input_type)]),
        .output_query = zx.columns.view(@FieldType(Input, "output_query"), self.state_plan.queries[@backingInt(function.output_type)]),
        .argument_kind = zx.columns.view(@FieldType(Input, "argument_kind"), self.program.expressions.kinds[@backingInt(invocation.argument)]),
        .expand_tuple = if (function.external) |external| external.expand_tuple else false,
        .active = self.state_active,
        .allows_allocation = self.allows_allocation,
        .function = index,
        .value_functions = self.value_functions,
        .constructed_outputs = self.constructed_outputs,
        .pure_functions = self.pure_functions,
        .local_functions = self.local_functions,
        .fresh_outputs = self.fresh_outputs,
        .io_functions = self.io_functions,
        .process_functions = self.process_functions,
        .stores = invocation.stores.len,
    };

    const frame: Frame = .{ .lowering = self, .invocation = invocation };
    const request: Request = .{ .frame = @ptrCast(&frame), .source = &source };

    return evaluation.invoke(entry, &request);
}

pub fn invokePlannedRegularCall(
    handle: *const anyopaque,
    argument: evaluation.Api.RegularCallArgument,
    convert_output: bool,
    stores: bool,
    io: bool,
    process: bool,
) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../invocation/execute.zig").regular(frame.lowering, frame.invocation, .{
        .argument = argument,
        .convert_output = convert_output,
        .stores = stores,
        .io = io,
        .process = process,
    }));
}

pub fn invokePlannedValueCall(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try value.invocation(frame.lowering, frame.invocation));
}

pub fn invokePlannedPointerCall(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try value.pointerInvocation(frame.lowering, frame.invocation));
}
