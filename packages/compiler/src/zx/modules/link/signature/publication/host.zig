const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const FunctionImport = @import("../../../function_import.zig");
const Error = @import("../../../artifact/model.zig").Error;
const columns = @import("../../../artifact/materializing/publication/columns.zig");
const rule = @import("generated_artifact_signature_publication");
const Parameter = @typeInfo(@TypeOf(rule.executeState)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const Source = @FieldType(Input, "source");

pub fn append(allocator: std.mem.Allocator, storage: *ir.FunctionStorage, source: ir.SignatureTable, resolution: anytype, mapping: []?ir.FunctionId) Error!void {
    const native_id = resolution.native_id orelse return error.InvalidModule;

    try storage.reserve(allocator, 1);

    const target = columns.borrow(@FieldType(Input, "columns"), storage.reservedTail(1), true);
    const signatures = if (@typeInfo(Source) == .pointer) zx.columns.columns(std.meta.Child(Source), source) else columns.borrow(Source, source, false);

    const input: Input = .{
        .source = if (@typeInfo(Source) == .pointer) &signatures else signatures,
        .row = resolution.next,
        .ports = .{
            .input = resolution.input_type,
            .output = resolution.output_type,
            .native_module = native_id,
        },
        .empty = &emptyBody(Empty),
        .columns = target,
        .mapping = @ptrCast(&mapping),
        .id = resolution.row,
    };

    const written = rule.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    columns.checkBorrow(target, written);
    storage.commitTail(1);
}

const publication = @import("generated_native_members_publication");
const NativeParameter = @typeInfo(@TypeOf(publication.executeState)).@"fn".param_types[1].?;
const NativeInput = if (@typeInfo(NativeParameter) == .pointer) std.meta.Child(NativeParameter) else NativeParameter;
const Rows = std.meta.Child(@FieldType(NativeInput, "rows"));
const Cached = std.meta.Child(@typeInfo(@FieldType(Rows, "cached")).optional.child);
const CacheSignatures = @FieldType(Cached, "signatures");
const NativeMember = std.meta.Elem(@FieldType(std.meta.Child(@import("generated_native_interface").Output), "members"));

pub const SourceRows = union(enum) {
    fresh: []const NativeMember,
    cached: struct {
        signatures: ir.SignatureTable,
        inputs: []const u32,
        outputs: []const u32,
    },
};

pub const Staged = struct {
    members: []const FunctionImport = &.{},
    namespace: ?[]const []const u8 = null,
};

/// Fills rows while the project retains control of when their lengths become visible.
pub fn stageNative(allocator: std.mem.Allocator, storage: *ir.FunctionStorage, source: SourceRows, path: []const u8, namespace: []const []const u8, module: ir.NativeModuleId) std.mem.Allocator.Error!Staged {
    const count = switch (source) {
        .fresh => |rows| rows.len,
        .cached => |rows| rows.signatures.count(),
    };

    if (count == 0) return .{};

    const members = try allocator.alloc(FunctionImport, count);

    try storage.reserve(allocator, count);

    const writable = FunctionImport.Writable.borrowRows(members);
    const target = columns.borrow(@FieldType(NativeInput, "functions"), storage.reservedTail(count), true);
    var cache_table: if (@typeInfo(CacheSignatures) == .pointer) std.meta.Child(CacheSignatures) else CacheSignatures = undefined;

    const rows: Rows = switch (source) {
        .fresh => |values| .{
            .fresh = zx.columns.slice(@FieldType(Rows, "fresh"), values),
            .cached = null,
            .count = count,
        },
        .cached => |values| cache: {
            cache_table = if (@typeInfo(CacheSignatures) == .pointer) zx.columns.columns(std.meta.Child(CacheSignatures), values.signatures) else columns.borrow(CacheSignatures, values.signatures, false);

            break :cache .{
                .fresh = &.{},
                .cached = &.{
                    .signatures = if (@typeInfo(CacheSignatures) == .pointer) &cache_table else cache_table,
                    .inputs = values.inputs,
                    .outputs = values.outputs,
                },
                .count = count,
            };
        },
    };

    const input: NativeInput = .{
        .rows = &rows,
        .owner = .{ .path = path, .namespace = .{ .items = namespace, .storage = .plain }, .module = @backingInt(module) },
        .functions = target,
        .members = &writable.view(std.meta.Child(@FieldType(NativeInput, "members"))),
        .first = storage.count(),
        .empty = &emptyBody(std.meta.Child(@FieldType(NativeInput, "empty"))),
    };

    const written = publication.executeState(allocator, if (@typeInfo(NativeParameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    columns.checkBorrow(target, written.functions);

    return .{ .members = members, .namespace = written.namespace.items };
}

fn emptyBody(comptime T: type) T {
    return .{
        .symbols = zx.columns.pointer(@FieldType(T, "symbols"), &ir.FunctionStorage.empty_symbols),
        .expressions = zx.columns.pointer(@FieldType(T, "expressions"), &ir.FunctionStorage.empty_expressions),
        .contracts = zx.columns.pointer(@FieldType(T, "contracts"), &ir.FunctionStorage.empty_contracts),
        .control = zx.columns.pointer(@FieldType(T, "control"), (ir.ControlBody{}).control),
        .stores = zx.columns.pointer(@FieldType(T, "stores"), &ir.FunctionStorage.empty_stores),
    };
}
