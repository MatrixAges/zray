const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Error = Lower.Error;

pub const Columns = struct {
    allocator: std.mem.Allocator,
    layouts: []u32 = undefined,
    operands: []u32 = undefined,
    pub fn bind(self: *Columns, comptime Shape: type, context: *Context, with_operands: bool) Shape {
        return .{
            .frame = @ptrCast(context),
            .storage = @ptrCast(self),
            .layouts = @ptrCast(&self.layouts),
            .operands = if (with_operands) @ptrCast(&self.operands) else null,
        };
    }
};

pub fn reserveIterationResources(handle: *anyopaque, length: u64, with_operands: bool) Error!void {
    const columns: *Columns = @ptrCast(@alignCast(handle));
    const count: usize = @intCast(length);
    columns.layouts = try columns.allocator.alloc(u32, count);

    if (with_operands) columns.operands = try columns.allocator.alloc(u32, count);
}

pub fn publish(context: *Context, types: []const u32, values: []const u32) Error!void {
    const cache = @import("generated_publish_iteration_type_cache");
    const input: std.meta.Child(cache.Input) = .{ .frame = @ptrCast(context), .types = types, .values = values };

    return evaluation.execute(cache, &input);
}

pub fn materializeIterationResource(handle: *anyopaque, id: u32, resource: evaluation.Api.IterationResource) Error!u32 {
    const context: *Context = @ptrCast(@alignCast(handle));
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

pub fn cacheIterationType(handle: *anyopaque, id: u32, value: u32) Error!void {
    const context: *Context = @ptrCast(@alignCast(handle));

    return context.types.put(context.lowering.allocator, @fromBackingInt(id), @fromBackingInt(value));
}
