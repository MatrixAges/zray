const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Native = @import("../../interface.zig").Native;
const Artifact = @import("../../artifact/model.zig");
const FunctionImport = @import("../../function_import.zig");
const Origins = @import("../../nominal_origins.zig");
const columns = @import("../../artifact/materializing/publication/columns.zig");
const rule = @import("generated_native_artifact_publication");
const Input = @typeInfo(@TypeOf(rule.executeState)).@"fn".param_types[1].?;

pub fn artifact(allocator: std.mem.Allocator, value: anytype, entry: Native, fingerprint: [32]u8) std.mem.Allocator.Error!Artifact.Module {
    const types = try @import("../../../analysis/type_table.zig").copy(allocator, zx.columns.view(ir.TypeTable, value.types));
    const exports = try allocator.alloc(ir.Export, value.exports.len);
    const bindings = try allocator.alloc(FunctionImport, value.members.len);
    const writable = FunctionImport.Writable.borrowRows(bindings);
    const export_rows = zx.memory.borrowNamedRows("type_id", exports);
    var signatures: ir.SignatureTable = undefined;

    inline for (@typeInfo(ir.SignatureTable).@"struct".field_names) |name| {
        @field(signatures, name) = try allocator.alloc(std.meta.Elem(@FieldType(ir.SignatureTable, name)), value.members.len);
    }

    const target = columns.borrow(@FieldType(Input, "signature_target"), signatures, true);
    const ExportRows = @FieldType(Input, "exports");
    const Members = @FieldType(Input, "members");
    const OriginInput = @FieldType(Input, "origins");
    const borrowed_origins = if (@typeInfo(OriginInput) == .pointer) zx.columns.view(std.meta.Child(OriginInput), value.origins) else {};

    const input: Input = .{
        .key = entry.key(),
        .declaration = &.{ .identity = entry.identity, .specifier = entry.specifier, .import_name = entry.module, .path = entry.path, .namespace = entry.namespace },
        .labels = .{ .items = types.labels, .storage = .plain },
        .origins = if (@typeInfo(OriginInput) == .pointer) &borrowed_origins else columns.borrow(OriginInput, value.origins, false),
        .exports = .{ .items = zx.columns.slice(@FieldType(ExportRows, "items"), value.exports), .storage = .plain },
        .members = .{ .items = zx.columns.slice(@FieldType(Members, "items"), value.members), .storage = .plain },
        .signature_target = target,
        .binding_target = &writable.view(std.meta.Child(@FieldType(Input, "binding_target"))),
        .export_target = @ptrCast(&export_rows),
    };

    const published = rule.executeState(allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    columns.checkBorrow(target, published.signatures);

    return .{
        .path = published.path,
        .source_digest = fingerprint,
        .types = types,
        .nominal_types = columns.view(Origins.Table, published.origins),
        .exports = exports,
        .function_imports = bindings,
        .functions = signatures,
        .native_modules = columns.view(ir.NativeModuleTable, published.modules),
        .dependencies = &.{},
        .type_imports = &.{},
        .function = null,
        .stores = .{},
    };
}
