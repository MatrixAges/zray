const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const seed = @import("seed.zig");
const value = @import("../value_call/root.zig");
const Operation = seed.Operation;
const Error = Lower.Error;

pub const Argument = if (@import("genz_options").generated_analysis)
    @FieldType(std.meta.Child(@import("generated_lower_planned_call").Output), "argument")

else
    enum { Value, ExternalTuple, ScalarBorrow, StateBorrow, StatePointer };

pub const Plan = struct {
    argument: Argument,
    convert_output: bool,
    stores: bool,
    io: bool,
    process: bool,
};

pub fn lower(self: *Lower, invocation: Operation) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return seed.lower(self, invocation);

    const entry = @import("generated_lower_planned_call");
    const Input = std.meta.Child(entry.Input);
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const Cache = std.meta.Child(@FieldType(Input, "cache"));
    const index = @backingInt(invocation.function);
    const functions = &self.program.functions;
    const input_type = functions.input_types[index];
    const output_type = functions.output_types[index];
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
        .input = input_type,
        .output = output_type,
        .input_query = zx.columns.view(@FieldType(Input, "input_query"), self.state_plan.queries[input_type]),
        .output_query = zx.columns.view(@FieldType(Input, "output_query"), self.state_plan.queries[output_type]),
        .argument_kind = zx.columns.view(@FieldType(Input, "argument_kind"), self.program.expressions.kinds[@backingInt(invocation.argument)]),
        .expand_tuple = functions.native_modules[index] != null and functions.native_tuples[index],
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

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const planned = entry.executeValue(memory.allocator(), &source) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };

    return switch (planned.route) {
        .Value => value.invocation(self, invocation),
        .Pointer => value.pointerInvocation(self, invocation),
        .Regular, .RegularRepresented => @import("../invocation/execute.zig").regular(self, invocation, .{
            .argument = planned.argument,
            .convert_output = planned.convert_output,
            .stores = planned.stores,
            .io = planned.io,
            .process = planned.process,
        }),
    };
}
