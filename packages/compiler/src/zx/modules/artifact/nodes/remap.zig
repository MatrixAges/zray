const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("generated_artifact_remap");
const functions = @import("generated_artifact_linked_function");
const Nodes = @import("../nodes.zig");
const Error = @import("../model.zig").Error;
const external_host = @import("../materializing/external_host.zig");
const Input = std.meta.Child(generated.Input);
const Mapping = std.meta.Child(@FieldType(Input, "type_mapping"));
const Output = @typeInfo(@TypeOf(generated.executeValue(undefined, undefined))).error_union.payload;
const Link = std.meta.Child(functions.Input);
const Admission = std.meta.Child(@FieldType(Link, "admission"));
const FunctionInput = std.meta.Child(@FieldType(Admission, "source"));
const Metadata = std.meta.Child(@FieldType(Link, "metadata"));
const External = std.meta.Child(@typeInfo(@FieldType(Metadata, "external")).optional.child);
const Control = @typeInfo(@FieldType(Link, "control")).optional.child;
const FunctionOutput = @typeInfo(@typeInfo(@TypeOf(functions.executeValue(undefined, undefined))).error_union.payload).optional.child;

pub const BodyColumns = struct {
    input_type: ir.TypeId,
    output_type: ir.TypeId,
    native_module: ?ir.NativeModuleId,
    symbols: *const ir.SymbolTable,
    expressions: *const ir.ExpressionTable,
    contracts: *const ir.ContractTable,
    stores: *const ir.StoreTable,
    pub fn borrow(value: *const ir.Function) BodyColumns {
        return .{
            .input_type = value.input_type,
            .output_type = value.output_type,
            .native_module = if (value.external) |external| external.module else null,
            .symbols = &value.symbols,
            .expressions = &value.expressions,
            .contracts = &value.contracts,
            .stores = &value.stores,
        };
    }

    pub fn at(table: *const ir.FunctionTable, row: usize) BodyColumns {
        return .{
            .input_type = @fromBackingInt(table.input_types[row]),
            .output_type = @fromBackingInt(table.output_types[row]),
            .native_module = if (table.native_modules[row]) |id| @fromBackingInt(id) else null,
            .symbols = table.symbols[row],
            .expressions = table.expressions[row],
            .contracts = table.contracts[row],
            .stores = table.stores[row],
        };
    }
};

pub fn columns(allocator: std.mem.Allocator, nodes: *const Nodes, types: []const u32, calls: []const u32) Error!Output {
    if (types.len == 0 and calls.len == 0) return .{ .types = &.{}, .functions = &.{} };

    const types_view = typeMapping(Mapping, nodes.types);
    const functions_view = idMapping(Mapping, nodes.functions);

    const input: Input = .{
        .types = types,
        .type_mapping = &types_view,
        .functions = calls,
        .function_mapping = &functions_view,
    };

    return zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| return failure(err);
}

pub fn function(nodes: *const Nodes, body: BodyColumns, control: ir.ControlBody, file: []const u8, native: ?ir.External, candidate: ?ir.FunctionId, structure: Nodes.Structure) Error!FunctionOutput {
    if (structure == .unchecked and !try @import("control.zig").valid(nodes.allocator, control)) return error.InvalidModule;

    var request: FunctionRequest = undefined;

    request.init(nodes, body, control, file, native, candidate, structure);

    const input: *const Link = &request.input;
    const mapped = zx.columns.invoke(functions.executeValue, nodes.allocator, input) catch |err| return failure(err);

    return mapped orelse error.InvalidModule;
}

pub const FunctionRequest = struct {
    view: FunctionView(FunctionInput),
    admission: Admission,
    metadata: Metadata,
    abi: ?External,
    input: Link,
    pub fn init(self: *FunctionRequest, nodes: *const Nodes, body: BodyColumns, control: ir.ControlBody, file: []const u8, native: ?ir.External, candidate: ?ir.FunctionId, structure: Nodes.Structure) void {
        self.view.initColumns(nodes, body, candidate);

        self.admission = .{
            .source = &self.view.input,
            .stores = zx.columns.pointer(@FieldType(Admission, "stores"), body.stores),
            .checked = structure == .validated,
            .max_offset = std.math.maxInt(usize),
        };

        self.abi = if (native) |value| external_host.borrow(External, value) else null;
        self.metadata = .{ .file = file, .external = if (self.abi) |*value| value else null };

        self.input = .{
            .admission = &self.admission,
            .metadata = &self.metadata,
            .control = if (control.root != null) zx.columns.pointer(Control, control.control) else null,
        };
    }
};

pub fn FunctionView(comptime T: type) type {
    const FunctionMapping = std.meta.Child(@FieldType(T, "types"));
    const Ports = std.meta.Child(@FieldType(T, "ports"));
    const Contracts = std.meta.Child(@FieldType(T, "contracts"));
    const Symbols = @FieldType(T, "symbols");
    const Expressions = @FieldType(T, "expressions");

    return struct {
        const Self = @This();
        types: FunctionMapping,
        functions: FunctionMapping,
        natives: FunctionMapping,
        ports: Ports,
        contracts: Contracts,
        input: T,
        pub fn init(self: *Self, nodes: *const Nodes, value: *const ir.Function, candidate: ?ir.FunctionId) void {
            self.initColumns(nodes, BodyColumns.borrow(value), candidate);
        }
        fn initColumns(self: *Self, nodes: *const Nodes, value: BodyColumns, candidate: ?ir.FunctionId) void {
            self.types = typeMapping(FunctionMapping, nodes.types);
            self.functions = idMapping(FunctionMapping, nodes.functions);
            self.natives = idMapping(FunctionMapping, nodes.native_modules);
            self.contracts = zx.columns.columns(Contracts, value.contracts.*);

            self.ports = .{
                .input = @backingInt(value.input_type),
                .output = @backingInt(value.output_type),
                .native_module = if (value.native_module) |id| @backingInt(id) else null,
            };

            self.input = .{
                .types = &self.types,
                .functions = &self.functions,
                .natives = &self.natives,
                .ports = &self.ports,
                .contracts = &self.contracts,
                .symbols = zx.columns.pointer(Symbols, value.symbols),
                .expressions = zx.columns.pointer(Expressions, value.expressions),
                .stores = value.stores.types,
                .candidate = if (candidate) |id| @backingInt(id) else null,
            };
        }
    };
}

pub fn validFunctionColumns(value: *const ir.Function) bool {
    const rule = @import("generated_ir_function_columns");
    const Columns = std.meta.Child(rule.Input);

    const input: Columns = .{
        .stores = zx.columns.pointer(@FieldType(Columns, "stores"), &value.stores),
        .symbols = zx.columns.pointer(@FieldType(Columns, "symbols"), &value.symbols),
        .expressions = zx.columns.pointer(@FieldType(Columns, "expressions"), &value.expressions),
        .contracts = zx.columns.pointer(@FieldType(Columns, "contracts"), &value.contracts),
        .max_offset = std.math.maxInt(usize),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch false;
}

pub fn typeMapping(comptime Target: type, mapping: Nodes.TypeMap) Target {
    return switch (mapping) {
        .collect => unreachable,
        .mapped => |ids| .{ .kind = .Dense, .dense = @ptrCast(ids), .sparse = &.{}, .planned = &.{}, .first = 0, .prefix = 0, .count = 0 },
        .planned => |ids| .{ .kind = .Planned, .dense = &.{}, .sparse = &.{}, .planned = ids, .first = 0, .prefix = 0, .count = 0 },
        .identity => |count| .{ .kind = .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = 0, .prefix = 0, .count = count },
    };
}

pub fn idMapping(comptime Target: type, mapping: anytype) Target {
    return switch (mapping) {
        .indexed => |ids| .{ .kind = .Sparse, .dense = &.{}, .sparse = @ptrCast(ids), .planned = &.{}, .first = 0, .prefix = 0, .count = 0 },
        .planned => |ids| .{ .kind = .Planned, .dense = &.{}, .sparse = &.{}, .planned = ids, .first = 0, .prefix = 0, .count = 0 },
        .range => |range| .{ .kind = .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = range.first, .prefix = range.prefix, .count = range.count },
    };
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModule,
    };
}
