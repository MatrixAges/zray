const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Types = @import("types.zig");
const Error = @import("model.zig").Error;
const Self = @This();
const IdMap = @import("nodes/id_map.zig").Map;
const own = @import("nodes/columns.zig").own;
const remap = @import("nodes/remap.zig");
const generated = @import("parser_options").generated_parser;

pub const TypeMap = union(enum) {
    collect: if (@import("parser_options").generated_parser) void else *Types,
    mapped: []const ir.TypeId,
    planned: []const u64,
    identity: u32,
    pub fn include(self: TypeMap, id: ir.TypeId) Error!ir.TypeId {
        return switch (self) {
            .collect => |types| if (comptime @import("parser_options").generated_parser) unreachable else types.include(id),
            .mapped => |mapping| if (@backingInt(id) < mapping.len) mapping[@backingInt(id)] else error.InvalidModule,
            .planned => |mapping| if (@backingInt(id) < mapping.len and mapping[@backingInt(id)] != 0) @fromBackingInt(@intCast(mapping[@backingInt(id)] - 1)) else error.InvalidModule,
            .identity => |count| if (@backingInt(id) < count) id else error.InvalidModule,
        };
    }
};

allocator: std.mem.Allocator,
types: TypeMap,
functions: IdMap(ir.FunctionId),
native_modules: IdMap(ir.NativeModuleId),
pub fn constants(self: *Self, values: []const ir.Constant) Error![]const ir.Constant {
    if (values.len == 0) return &.{};

    if (comptime generated) {
        const surface = @import("surface.zig");
        const types = remap.typeMapping(surface.Mapping, self.types);

        return surface.copyConstants(self.allocator, values, &types);
    }

    const result = try self.allocator.alloc(ir.Constant, values.len);

    for (values, result) |value, *owned| {
        owned.* = try @import("../../analysis/constants/copy.zig").copy(self.allocator, value);
        owned.type_id = try self.types.include(value.type_id);
    }

    return result;
}

pub fn functionId(self: *Self, id: ir.FunctionId) Error!ir.FunctionId {
    return self.functions.get(id);
}

pub fn function(self: *Self, value: ir.Function) Error!ir.Function {
    return (try self.functionEntry(value, null, .unchecked)).body;
}

pub fn appendFunctions(self: *Self, storage: *ir.FunctionStorage, table: ir.FunctionTable, temporary: std.mem.Allocator) Error!void {
    const count = table.count();

    if (count == 0) return;

    if (comptime generated) {
        try @import("materializing/publication/host.zig").append(self, storage, table, temporary);
    } else {
        for (0..count) |row| try storage.append(self.allocator, try self.function(table.at(row)));
    }
}

pub fn appendFunction(self: *Self, storage: *ir.FunctionStorage, value: *const ir.Function, temporary: std.mem.Allocator) Error!void {
    if (comptime generated) {
        try @import("materializing/publication/host.zig").appendOne(self, storage, value, temporary);
    } else {
        try storage.append(self.allocator, try self.function(value.*));
    }
}

pub const Structure = enum { unchecked, validated };
pub const remapInitializer = @import("nodes/initializer.zig").remap;

pub const FunctionEntry = struct {
    body: ir.Function,
    recursive: ?ir.FunctionId = null,
    descriptors: ?ir.FunctionStorage.Descriptors = null,
};

pub fn functionEntry(self: *Self, value: ir.Function, candidate: ?ir.FunctionId, structure: Structure) Error!FunctionEntry {
    if (comptime generated) {
        const linked = try remap.function(self, remap.BodyColumns.borrow(&value), value.body, value.file_name, value.external, candidate, structure);

        return .{
            .body = linkedFunction(&value, linked),
            .recursive = if (linked.recursive) |id| @fromBackingInt(id) else null,
            .descriptors = if (linked.recursive != null) .{
                .symbols = zx.columns.pointer(*const ir.SymbolTable, linked.symbols),
                .expressions = zx.columns.pointer(*const ir.ExpressionTable, linked.expressions),
                .stores = if (linked.store_table) |store_table| zx.columns.pointer(*const ir.StoreTable, store_table) else null,
                .contracts = zx.columns.pointer(*const ir.ContractTable, linked.contracts),
            } else null,
        };
    }

    var result = value;

    result.file_name = try self.allocator.dupe(u8, value.file_name);
    result.input_type = try self.types.include(value.input_type);
    result.output_type = try self.types.include(value.output_type);
    result.symbols = try self.symbolsSeed(value.symbols);
    result.expressions = try self.expressionsSeed(value.expressions);
    result.body = try self.bodySeed(value.body);
    result.stores = try self.stores(value.stores);
    result.contracts = try self.contractsSeed(value.contracts);
    result.external = if (value.external) |entry| try self.external(entry) else null;

    const recursive = if (candidate) |id| if (@import("../function_body.zig").calls(result.expressions, id)) id else null else null;

    return .{ .body = result, .recursive = recursive };
}

pub fn linkedFunction(value: *const ir.Function, linked: anytype) ir.Function {
    var result = materializeBody(value, linked, controlBody(value.body.root, linked.control));
    result.file_name = linked.file;
    result.stores = if (linked.store_table) |store_table| zx.columns.view(ir.StoreTable, store_table) else .{};
    result.external = linkedExternal(value.external, linked);

    return result;
}

fn linkedExternal(value: ?ir.External, linked: anytype) ?ir.External {
    const source = value orelse return null;
    const module: ir.NativeModuleId = @fromBackingInt(linked.ports.native_module.?);

    return @import("materializing/external_host.zig").apply(source, module, linked.external.?);
}

pub fn controlBody(root: ?ir.BlockId, table: anytype) ir.ControlBody {
    return if (table) |owned|
        .{ .control = zx.columns.pointer(*const ir.ControlTable, owned), .root = root }

    else
        .{};
}

pub fn materializeBody(value: *const ir.Function, mapped: anytype, control: ir.ControlBody) ir.Function {
    return .{
        .file_name = value.file_name,
        .input_type = @fromBackingInt(mapped.ports.input),
        .output_type = @fromBackingInt(mapped.ports.output),
        .output_ownership = value.output_ownership,
        .store_mode = value.store_mode,
        .symbols = zx.columns.view(ir.SymbolTable, mapped.symbols),
        .expressions = zx.columns.view(ir.ExpressionTable, mapped.expressions),
        .body = control,
        .contracts = zx.columns.view(ir.ContractTable, mapped.contracts),
    };
}

pub fn stores(self: *Self, values: ir.StoreTable) Error!ir.StoreTable {
    if (comptime generated) return @import("materializing/stores/host.zig").remap(self, &values);
    if (!values.validStructure()) return error.InvalidModule;

    var storage: ir.StoreStorage = .{};

    errdefer storage.deinit(self.allocator);

    for (0..values.count()) |index| {
        var item = values.at(index);

        item.path = try self.allocator.dupe(u8, item.path);
        item.handle = try self.allocator.dupe(u8, item.handle);
        item.type_id = try self.types.include(item.type_id);

        try storage.append(self.allocator, item);
    }

    return storage.finish(self.allocator);
}

fn symbolsSeed(self: *Self, values: ir.SymbolTable) Error!ir.SymbolTable {
    if (!values.validStructure()) return error.InvalidModule;

    var storage: ir.SymbolStorage = .{};

    errdefer storage.deinit(self.allocator);

    for (0..values.count()) |index| {
        var item = values.at(index);

        item.name = try self.allocator.dupe(u8, item.name);
        item.type_id = try self.types.include(item.type_id);

        try storage.append(self.allocator, item);
    }

    return storage.finish(self.allocator);
}

fn expressionsSeed(self: *Self, values: ir.ExpressionTable) Error!ir.ExpressionTable {
    @setEvalBranchQuota(100_000);

    if (!values.validStructure()) return error.InvalidModule;

    var result: ir.ExpressionTable = .{};

    inline for (@typeInfo(ir.ExpressionTable).@"struct".field_names) |name| {
        const source = @field(values, name);
        const owned = try self.allocator.dupe(@typeInfo(@TypeOf(source)).pointer.child, source);

        if (comptime std.mem.eql(u8, name, "types")) {
            for (owned) |*id| id.* = @backingInt(try self.types.include(@fromBackingInt(id.*)));
        } else if (comptime std.mem.eql(u8, name, "call_functions")) {
            for (owned) |*id| id.* = @backingInt(try self.functionId(@fromBackingInt(id.*)));
        } else if (comptime std.mem.eql(u8, name, "strings")) {
            for (owned) |*text| text.* = try self.allocator.dupe(u8, text.*);
        }

        @field(result, name) = owned;
    }

    return result;
}

fn contractsSeed(self: *Self, values: ir.ContractTable) Error!ir.ContractTable {
    if (!values.validStructure()) return error.InvalidModule;
    if (values.count() == 0) return .{};

    const owned_symbols = try self.allocator.alloc(*const ir.SymbolTable, values.count());
    const owned_expressions = try self.allocator.alloc(*const ir.ExpressionTable, values.count());

    for (values.symbols, values.expressions, owned_symbols, owned_expressions) |source_symbols, source_expressions, *symbols_slot, *expressions_slot| {
        const symbol_table = try self.allocator.create(ir.SymbolTable);
        const expression_table = try self.allocator.create(ir.ExpressionTable);
        symbol_table.* = try self.symbolsSeed(source_symbols.*);
        expression_table.* = try self.expressionsSeed(source_expressions.*);
        symbols_slot.* = symbol_table;
        expressions_slot.* = expression_table;
    }

    return own(self.allocator, values, .{ .symbols = owned_symbols, .expressions = owned_expressions });
}

fn bodySeed(self: *Self, value: ir.ControlBody) Error!ir.ControlBody {
    if (!try value.validStructure(self.allocator)) return error.InvalidModule;
    if (value.root == null) return .{};

    const table = try self.allocator.create(ir.ControlTable);

    table.* = try own(self.allocator, value.control.*, .{});

    return .{ .control = table, .root = value.root };
}

pub fn external(self: *Self, value: ir.External) Error!ir.External {
    return self.externalMapped(value, try self.native_modules.get(value.module));
}

pub fn externalMapped(self: *Self, value: ir.External, module: ir.NativeModuleId) Error!ir.External {
    if (comptime generated) return @import("materializing/external_host.zig").own(self.allocator, value, module);

    var result = value;

    result.module = module;
    result.member = try self.strings(value.member);
    result.errors = if (value.errors) |errors| try self.strings(errors) else null;
    result.export_name = if (value.export_name) |name| try self.allocator.dupe(u8, name) else null;
    result.input = if (value.input) |input| try self.nativeType(input) else null;

    return result;
}

fn nativeType(self: *Self, value: ir.NativeType) Error!ir.NativeType {
    const names = try self.allocator.alloc(?[]const u8, value.names.len);

    for (value.names, names) |name, *owned| owned.* = if (name) |text| try self.allocator.dupe(u8, text) else null;

    return .{ .names = names };
}

pub fn strings(self: *Self, values: []const []const u8) Error![]const []const u8 {
    const result = try self.allocator.alloc([]const u8, values.len);

    for (values, result) |value, *owned| owned.* = try self.allocator.dupe(u8, value);

    return result;
}
