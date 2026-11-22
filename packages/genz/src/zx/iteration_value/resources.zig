const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const entry = @import("generated_resolve_iteration_resources");
const Input = std.meta.Child(entry.Input);
const Error = Lower.Error;

const Plan = union(enum) {
    borrowed: @FieldType(Input, "borrowed"),
    input: @FieldType(Input, "operations"),
    returned: @FieldType(Input, "requirements"),
    leaves,
};

pub fn layouts(
    context: *Context,
    allocator: std.mem.Allocator,
    types: []const u32,
    root: node.ExpressionId,
    plan: Plan,
) Error![]const u32 {
    var output = try allocator.alloc(u32, types.len);

    try resolve(context, types, root, plan, &output, null);

    return output;
}

pub fn conversion(
    context: *Context,
    allocator: std.mem.Allocator,
    types: []const u32,
    root: node.ExpressionId,
    plan: Plan,
) Error!struct { layouts: []const u32, operands: []const u32 } {
    var output = try allocator.alloc(u32, types.len);
    var operands = try allocator.alloc(u32, types.len);

    try resolve(context, types, root, plan, &output, &operands);

    return .{ .layouts = output, .operands = operands };
}

fn resolve(
    context: *Context,
    types: []const u32,
    root: node.ExpressionId,
    plan: Plan,
    output: *[]u32,
    operands: ?*[]u32,
) Error!void {
    const input: Input = .{
        .frame = @ptrCast(context),
        .mode = switch (plan) {
            .borrowed => .Borrow,
            .input => .Input,
            .returned => .Returned,
            .leaves => .Leaves,
        },
        .root = @backingInt(root),
        .types = types,
        .borrowed = if (plan == .borrowed) plan.borrowed else &.{},
        .operations = if (plan == .input) plan.input else &.{},
        .requirements = if (plan == .returned) plan.returned else &.{},
        .layouts = @ptrCast(output),
        .operands = if (operands) |items| @ptrCast(items) else null,
    };

    return evaluation.execute(entry, &input);
}

pub fn publish(context: *Context, types: []const u32, values: []const u32) Error!void {
    const cache = @import("generated_publish_iteration_type_cache");
    const input: std.meta.Child(cache.Input) = .{ .frame = @ptrCast(context), .types = types, .values = values };

    return evaluation.execute(cache, &input);
}

pub fn materializeIterationResource(handle: *const anyopaque, id: u32, resource: evaluation.Api.IterationResource) Error!u32 {
    const context: *Context = @ptrCast(@alignCast(@constCast(handle)));
    const self = context.lowering;
    const type_id: ir.TypeId = @fromBackingInt(id);
    const types = @import("types.zig");

    return @backingInt(switch (resource) {
        .IterationType => try types.get(context, type_id),
        .IterationItem => try types.get(context, self.program.typeOf(type_id).list),
        .NativeLayout => try self.layoutExpr(type_id),
        .NativeType => try self.typeExpr(type_id),
        .StateLayout => try @import("../types.zig").get(self, self.state_layouts, type_id),
        .None, .Invalid => unreachable,
    });
}

pub fn cacheIterationType(handle: *const anyopaque, id: u32, value: u32) Error!void {
    const context: *Context = @ptrCast(@alignCast(@constCast(handle)));

    return context.types.put(context.lowering.allocator, @fromBackingInt(id), @fromBackingInt(value));
}
