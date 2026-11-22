const zx = @import("zx");
const ir = zx.ir;

pub fn function(value: anytype) ir.Function {
    return .{
        .file_name = value.file,
        .input_type = @fromBackingInt(value.ports.input),
        .output_type = @fromBackingInt(value.ports.output),
        .output_ownership = @fromBackingInt(@intCast(@backingInt(value.ownership))),
        .store_mode = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
        .symbols = zx.columns.view(ir.SymbolTable, value.symbols),
        .expressions = zx.columns.view(ir.ExpressionTable, value.expressions),
        .contracts = zx.columns.view(ir.ContractTable, value.contracts),
        .body = control(value.root, value.control),
        .stores = if (value.store_table) |table| zx.columns.view(ir.StoreTable, table) else .{},
        .external = if (value.external) |native| .{
            .module = @fromBackingInt(value.ports.native_module.?),
            .input = if (native.parameters) |parameters| .{ .names = parameters } else null,
            .member = native.members,
            .export_name = native.export_name,
            .errors = native.errors,
            .allocator_argument = value.allocator_argument,
            .io_argument = value.io_argument,
            .process_argument = value.process_argument,
            .expand_tuple = value.expand_tuple,
            .fallible = value.fallible,
            .concurrent = value.concurrent,
        } else null,
    };
}

pub fn control(root: ?u32, table: anytype) ir.ControlBody {
    return if (table) |borrowed|
        .{ .control = zx.columns.pointer(*const ir.ControlTable, borrowed), .root = if (root) |id| @fromBackingInt(id) else null }

    else
        .{};
}
