const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;

pub fn publish(allocator: std.mem.Allocator, program: *ir.Program, update: anytype) std.mem.Allocator.Error!void {
    if (update.selected) |body| applyBody(program, body);
    if (update.forwarded) |body| try applyForward(allocator, program, body);
}

pub fn applyBody(target: *anyopaque, body: anytype) void {
    const program: *ir.Program = @ptrCast(@alignCast(target));
    program.file_name = body.files;
    program.type_only = false;
    program.input_type = @fromBackingInt(body.input_types);
    program.output_type = @fromBackingInt(body.output_types);
    program.output_ownership = @fromBackingInt(@backingInt(body.ownership));
    program.store_mode = @fromBackingInt(@backingInt(body.store_modes));
    program.symbols = columns.borrow(ir.SymbolTable, body.symbols);
    program.expressions = columns.borrow(ir.ExpressionTable, body.expressions);
    program.contracts = columns.borrow(ir.ContractTable, body.contracts);
    program.stores = columns.borrow(ir.StoreTable, body.stores);

    program.body = .{
        .control = columns.pointer(*const ir.ControlTable, body.control),
        .root = if (body.roots) |id| @fromBackingInt(id) else null,
    };
}

pub fn applyForward(allocator: std.mem.Allocator, target: *anyopaque, wrapper: anytype) std.mem.Allocator.Error!void {
    const program: *ir.Program = @ptrCast(@alignCast(target));
    const control = try allocator.create(ir.ControlTable);
    control.* = columns.view(ir.ControlTable, wrapper.control);
    program.symbols = columns.view(ir.SymbolTable, wrapper.symbols);
    program.expressions = columns.view(ir.ExpressionTable, wrapper.expressions);
    program.contracts = columns.view(ir.ContractTable, wrapper.contracts);
    program.body = .{ .control = control, .root = @fromBackingInt(wrapper.root) };
}
