const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Model = @import("../../artifact/model.zig");
const Nodes = @import("../../artifact/nodes.zig");

pub const Tables = struct {
    types: ir.TypeTable,
    functions: ir.FunctionTable,
    native_modules: ir.NativeModuleTable,
};

pub fn fromPublication(path: []const u8, published: anytype, tables: Tables, exports: []const ir.Export, constants: []const ir.Constant) ir.Program {
    const payload = published.body;

    return .{
        .file_name = path,
        .types = tables.types,
        .input_type = @fromBackingInt(published.ports.input_type),
        .output_type = @fromBackingInt(published.ports.output_type),
        .output_ownership = @fromBackingInt(@intCast(@backingInt(published.ports.ownership))),
        .symbols = if (payload) |value| zx.columns.view(ir.SymbolTable, value.symbols) else .{},
        .expressions = if (payload) |value| zx.columns.view(ir.ExpressionTable, value.expressions) else .{},
        .body = if (payload) |value| @import("../../artifact/materializing/descriptor.zig").control(value.root, value.control) else .{},
        .contracts = if (payload) |value| zx.columns.view(ir.ContractTable, value.contracts) else .{},
        .exports = exports,
        .constant_exports = constants,
        .functions = tables.functions,
        .native_modules = tables.native_modules,
        .stores = zx.columns.view(ir.StoreTable, published.stores),
        .store_mode = @fromBackingInt(@intCast(@backingInt(published.ports.store_mode))),
        .type_only = payload == null,
    };
}

pub fn materialize(allocator: std.mem.Allocator, module: *const Model.Module, body: ?*const ir.Function, recursive: ?ir.FunctionId, tables: Tables, mapping: []const ir.TypeId) Model.Error!ir.Program {
    var assembled = try assemble(allocator, module, body, tables, mapping);

    if (recursive) |id| try @import("../../function_body.zig").entry(allocator, &assembled, id);

    return assembled;
}

pub fn assemble(allocator: std.mem.Allocator, module: *const Model.Module, body: ?*const ir.Function, tables: Tables, mapping: []const ir.TypeId) Model.Error!ir.Program {
    var nodes: Nodes = .{ .allocator = allocator, .types = .{ .mapped = mapping }, .functions = .{ .indexed = &.{} }, .native_modules = .{ .indexed = &.{} } };
    const stores = try nodes.stores(module.stores);
    const exports = try allocator.alloc(ir.Export, module.exports.len);

    for (exports, module.exports) |*item, original| {
        item.* = .{ .name = try allocator.dupe(u8, original.name), .type_id = try nodes.types.include(original.type_id) };
    }

    const constant_exports = try nodes.constants(module.constant_exports);

    return program(try allocator.dupe(u8, module.path), body, tables, stores, exports, constant_exports);
}

pub fn program(path: []const u8, body: ?*const ir.Function, tables: Tables, stores: ir.StoreTable, exports: []const ir.Export, constant_exports: []const ir.Constant) ir.Program {
    const unit: ir.TypeId = @fromBackingInt(@as(u32, @backingInt(ir.Scalar.void)));

    return .{
        .file_name = path,
        .types = tables.types,
        .input_type = if (body) |value| value.input_type else unit,
        .output_type = if (body) |value| value.output_type else unit,
        .output_ownership = if (body) |value| value.output_ownership else .borrowed,
        .symbols = if (body) |value| value.symbols else .{},
        .expressions = if (body) |value| value.expressions else .{},
        .body = if (body) |value| value.body else .{},
        .contracts = if (body) |value| value.contracts else .{},
        .exports = exports,
        .constant_exports = constant_exports,
        .functions = tables.functions,
        .native_modules = tables.native_modules,
        .stores = stores,
        .store_mode = if (body) |value| value.store_mode else .transaction,
        .type_only = body == null,
    };
}
