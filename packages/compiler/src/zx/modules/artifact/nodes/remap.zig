const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("generated_artifact_remap");
const extract = @import("generated_artifact_extract");
const functions = @import("generated_artifact_linked_function");
const Nodes = @import("../nodes.zig");
const Error = @import("../model.zig").Error;
const external_host = @import("../materializing/external_host.zig");
const Input = std.meta.Child(generated.Input);
const Mapping = std.meta.Child(@FieldType(Input, "type_mapping"));
const Output = @typeInfo(@TypeOf(generated.executeValue(undefined, undefined))).error_union.payload;
const Views = std.meta.Child(@FieldType(std.meta.Child(extract.Input), "materialization"));
const Content = std.meta.Child(@FieldType(Views, "content"));
const Link = std.meta.Child(@typeInfo(@FieldType(Content, "function")).optional.child);
const Admission = std.meta.Child(@FieldType(Link, "admission"));
const FunctionInput = std.meta.Child(@FieldType(Admission, "source"));
const Metadata = std.meta.Child(@FieldType(Link, "metadata"));
const External = std.meta.Child(@typeInfo(@FieldType(Metadata, "external")).optional.child);
const Control = @typeInfo(@FieldType(Link, "control")).optional.child;
const Attributes = std.meta.Child(@FieldType(Link, "attributes"));
const FunctionOutput = @typeInfo(@typeInfo(@TypeOf(functions.executeValue(undefined, undefined))).error_union.payload).optional.child;

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

pub fn function(nodes: *const Nodes, source: *const ir.FunctionView, candidate: ?ir.FunctionId, structure: Nodes.Structure) Error!FunctionOutput {
    if (structure == .unchecked and !try @import("control.zig").valid(nodes.allocator, source.body)) return error.InvalidModule;

    var request: FunctionRequest = undefined;

    request.init(nodes, source, candidate, structure);

    const mapped = zx.columns.invoke(functions.executeValue, nodes.allocator, &request.input) catch |err| return failure(err);

    return mapped orelse error.InvalidModule;
}

pub const FunctionRequest = struct {
    view: FunctionView(FunctionInput),
    admission: Admission,
    metadata: Metadata,
    abi: ?External,
    attributes: Attributes,
    input: Link,
    pub fn init(self: *FunctionRequest, nodes: *const Nodes, source: *const ir.FunctionView, candidate: ?ir.FunctionId, structure: Nodes.Structure) void {
        self.view.initBorrowed(nodes, source, candidate);

        self.admission = .{
            .source = &self.view.input,
            .stores = zx.columns.pointer(@FieldType(Admission, "stores"), source.stores),
            .checked = structure == .validated,
            .max_offset = std.math.maxInt(usize),
        };

        self.abi = if (source.signature.external) |value| external_host.borrow(External, value) else null;
        self.metadata = .{ .file = source.signature.file_name, .external = if (self.abi) |*value| value else null };
        self.attributes = attributes(Attributes, source, source.store_mode);

        self.input = .{
            .admission = &self.admission,
            .metadata = &self.metadata,
            .attributes = &self.attributes,
            .control = if (source.body.root != null) zx.columns.pointer(Control, source.body.control) else null,
        };
    }
};

pub fn attributes(comptime Target: type, source: *const ir.FunctionView, store_mode: ir.StoreMode) Target {
    const native = source.signature.external;

    return .{
        .ownership = @fromBackingInt(@intCast(@backingInt(source.signature.output_ownership))),
        .store_mode = @fromBackingInt(@intCast(@backingInt(store_mode))),
        .root = if (source.body.root) |id| @backingInt(id) else null,
        .allocator_argument = if (native) |value| value.allocator_argument else false,
        .io_argument = if (native) |value| value.io_argument else false,
        .process_argument = if (native) |value| value.process_argument else false,
        .expand_tuple = if (native) |value| value.expand_tuple else false,
        .fallible = if (native) |value| value.fallible else false,
        .concurrent = if (native) |value| value.concurrent else false,
    };
}

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
            const source = ir.FunctionView.borrow(value);

            self.initBorrowed(nodes, &source, candidate);
        }
        fn initBorrowed(self: *Self, nodes: *const Nodes, value: *const ir.FunctionView, candidate: ?ir.FunctionId) void {
            self.types = typeMapping(FunctionMapping, nodes.types);
            self.functions = idMapping(FunctionMapping, nodes.functions);
            self.natives = idMapping(FunctionMapping, nodes.native_modules);
            self.contracts = zx.columns.columns(Contracts, value.contracts.*);

            self.ports = .{
                .input = @backingInt(value.signature.input_type),
                .output = @backingInt(value.signature.output_type),
                .native_module = if (value.signature.external) |native| @backingInt(native.module) else null,
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
    const input = functionColumns(std.meta.Child(rule.Input), value);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch false;
}

pub fn functionColumns(comptime Columns: type, value: *const ir.Function) Columns {
    return .{
        .stores = zx.columns.pointer(@FieldType(Columns, "stores"), &value.stores),
        .symbols = zx.columns.pointer(@FieldType(Columns, "symbols"), &value.symbols),
        .expressions = zx.columns.pointer(@FieldType(Columns, "expressions"), &value.expressions),
        .contracts = zx.columns.pointer(@FieldType(Columns, "contracts"), &value.contracts),
        .max_offset = std.math.maxInt(usize),
    };
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
