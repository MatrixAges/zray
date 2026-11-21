const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Context = @import("context.zig");
const analysis = @import("generated_uniqueness_function_plan");
const independent = @import("generated_uniqueness_function_entry");

pub fn build(function: *Function, allocator: std.mem.Allocator) std.mem.Allocator.Error!Function.Plan {
    return generate(analysis, function, allocator);
}

pub fn entry(function: *Function, allocator: std.mem.Allocator) std.mem.Allocator.Error!Function.Plan {
    return generate(independent, function, allocator);
}

fn generate(comptime workflow: type, function: *Function, allocator: std.mem.Allocator) std.mem.Allocator.Error!Function.Plan {
    const Input = std.meta.Child(workflow.Input);
    var borrowed: Context = undefined;

    borrowed.init(function);

    const context: *const @TypeOf(borrowed.descriptor) = &borrowed.descriptor;
    const scratch = function.allocator;
    var scope = zx.memory.ArenaScope{ .active = scratch };
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), function.slots.types);

    const input: Input = .{
        .context = zx.columns.pointer(@FieldType(Input, "context"), context),
        .types = &types,
        .time = function.facts.nodes.time,
        .operations = @ptrCast(function.operations),
        .repeated = function.facts.repeated.owner,
        .results = function.facts.results,
        .arenas = &.{
            .scope = @ptrCast(&scope),
            .scratch = @ptrCast(&scratch),
            .owner = @ptrCast(&allocator),
        },
    };

    const result = workflow.executeValue(scope.allocator(), &input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        std.debug.panic("function plan failed: {s}", .{@errorName(err)});
    };

    return Function.Plan.fromColumns(result);
}
