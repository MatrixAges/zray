const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const Layout = @import("project_execution_abi").layouts.@"zig:memory/columns";

pub fn writeFunctionBody(target: *const anyopaque, bytes: []const u8) void {
    applyBody(target, bodyView(Layout.FunctionBodyRow, bytes));
}

pub fn writeForwardedBody(allocator: std.mem.Allocator, target: *const anyopaque, bytes: []const u8) std.mem.Allocator.Error!void {
    try applyForward(allocator, target, bodyView(Layout.ForwardedBody, bytes));
}

fn bodyView(comptime Body: type, bytes: []const u8) *const Body {
    std.debug.assert(bytes.len == @sizeOf(Body));

    return @ptrCast(@alignCast(bytes.ptr));
}

pub fn applyBody(target: *const anyopaque, body: anytype) void {
    const program: *ir.Program = @ptrCast(@alignCast(@constCast(target)));

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

pub fn applyForward(allocator: std.mem.Allocator, target: *const anyopaque, wrapper: anytype) std.mem.Allocator.Error!void {
    const program: *ir.Program = @ptrCast(@alignCast(@constCast(target)));
    const control = try allocator.create(ir.ControlTable);
    control.* = columns.view(ir.ControlTable, wrapper.control);
    program.symbols = columns.view(ir.SymbolTable, wrapper.symbols);
    program.expressions = columns.view(ir.ExpressionTable, wrapper.expressions);
    program.contracts = columns.view(ir.ContractTable, wrapper.contracts);
    program.body = .{ .control = control, .root = @fromBackingInt(wrapper.root) };
}
