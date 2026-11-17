const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const levels = @import("levels.zig");
const plan = @import("plan.zig");
const generated = @import("generated_uniqueness_function_entry");
const Input = std.meta.Child(generated.Input);

pub fn analyze(function: *Function, allocator: std.mem.Allocator) std.mem.Allocator.Error!Function.Plan {
    var borrowed: levels.Borrowed = undefined;

    try borrowed.init(function);

    const context: *const @TypeOf(borrowed.descriptor) = &borrowed.descriptor;
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), function.slots.types);
    const summaries = function.summaries;

    const input: Input = .{
        .context = zx.columns.pointer(@FieldType(Input, "context"), context),
        .types = &types,
        .time = function.order.nodes.time,
        .operations = @ptrCast(function.operations),
        .repeated = @ptrCast(function.order.repeated),
        .results = @ptrCast(function.order.results),
        .inputs = @ptrCast(&summaries.inputs),
        .outputs = @ptrCast(&summaries.outputs),
        .native_modules = function.functions.native_modules,
    };

    const facts = zx.columns.invoke(generated.executeValue, function.allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("independent entry analysis failed: {s}", .{@errorName(err)}),
    };

    return plan.publish(function, allocator, &borrowed, facts);
}
