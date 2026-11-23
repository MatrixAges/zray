const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub const Call = struct {
    id: ir.FunctionId,
    parameter: ir.Symbol,
    unit: bool,
    store_types: []const u32 = &.{},
};

pub fn write(allocator: std.mem.Allocator, program: *ir.Program, call: Call) std.mem.Allocator.Error!void {
    if (comptime !@import("parser_options").generated_parser) return @import("seed.zig").write(allocator, program, call);

    const generated = @import("generated_recursive_forward_entry");
    const Input = std.meta.Child(generated.Input);
    const Parameter = std.meta.Child(@FieldType(Input, "parameter"));
    const Ownership = @FieldType(Parameter, "ownership");
    const source = call.parameter;

    const parameter: Parameter = .{
        .name = source.name,
        .type_id = @backingInt(source.type_id),
        .ownership = switch (source.ownership) {
            .copy => Ownership.Copy,
            .borrowed => Ownership.Borrowed,
            .owned => Ownership.Owned,
        },
        .span_start = source.span.start,
        .span_end = source.span.end,
    };

    const input: Input = .{
        .parameter = &parameter,
        .input_type = @backingInt(program.input_type),
        .output_type = @backingInt(program.output_type),
        .function_id = @backingInt(call.id),
        .unit = call.unit,
        .store_types = call.store_types,
    };

    const wrapper = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const body = if (@typeInfo(@TypeOf(wrapper)) == .pointer) wrapper else &wrapper;

    try @import("../entry_body/host.zig").applyForward(allocator, @ptrCast(program), body);
}
