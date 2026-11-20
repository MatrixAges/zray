const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Context = @import("context.zig");
const analysis = @import("generated_uniqueness_function_plan");
const publication = @import("generated_uniqueness_function_plan_finish");
const Input = std.meta.Child(analysis.Input);
const Finish = std.meta.Child(publication.Input);

pub fn build(function: *Function, allocator: std.mem.Allocator) std.mem.Allocator.Error!Function.Plan {
    var borrowed: Context = undefined;

    try borrowed.init(function);

    const context: *const @TypeOf(borrowed.descriptor) = &borrowed.descriptor;
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), function.slots.types);

    const input: Input = .{
        .context = zx.columns.pointer(@FieldType(Input, "context"), context),
        .types = &types,
        .time = function.facts.nodes.time,
        .operations = @ptrCast(function.operations),
        .repeated = function.facts.repeated.owner,
        .results = function.facts.results,
    };

    const facts = zx.columns.invoke(analysis.executeValue, function.allocator, &input) catch |err| return failure(err);

    return publish(function, allocator, &borrowed, facts);
}

pub fn publish(function: *const Function, allocator: std.mem.Allocator, borrowed: *const Context, facts: anytype) std.mem.Allocator.Error!Function.Plan {
    const finish: Finish = .{
        .metadata = zx.columns.pointer(@FieldType(Finish, "metadata"), &borrowed.metadata),
        .type_kinds = function.slots.types.kinds,
        .flags = facts.flags,
        .keys = facts.keys,
        .writable = facts.writable,
        .needed = facts.needed,
    };

    const result = zx.columns.invoke(publication.executeValue, allocator, &finish) catch |err| return failure(err);

    return .{
        .flags = @ptrCast(result.flags),
        .renewals = .{ .keys = result.renewals.keys, .paths = result.renewals.paths },
        .transfers = result.transfers,
        .slot_first = result.slot_first,
    };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("function plan failed: {s}", .{@errorName(err)});
}
