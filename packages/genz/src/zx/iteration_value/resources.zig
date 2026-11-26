const zx = @import("zx");
const ir = zx.ir;
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Error = Lower.Error;

pub const Columns = struct {
    layouts: []u32 = undefined,
    operands: []u32 = undefined,
    pub fn bind(self: *Columns, comptime Shape: type, context: *Context, with_operands: bool) Shape {
        return .{
            .frame = @ptrCast(context),
            .layouts = @ptrCast(&self.layouts),
            .operands = if (with_operands) @ptrCast(&self.operands) else null,
        };
    }
};

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

pub fn recordIterationTransfer(handle: *anyopaque, type_id: u32, owner: u32, value: u32, ready: u32) Error!void {
    const context: *Context = @ptrCast(@alignCast(handle));

    return context.transfers.retain(context.lowering.allocator, type_id, owner, value, ready);
}
