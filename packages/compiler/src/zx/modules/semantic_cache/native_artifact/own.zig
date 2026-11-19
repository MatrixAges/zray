const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Native = @import("../../interface.zig").Native;
const Artifact = @import("../../artifact/model.zig");
const FunctionImport = @import("../../function_import.zig");
const Origins = @import("../../nominal_origins.zig");
const columns = @import("../../artifact/materializing/publication/columns.zig");
const rule = @import("generated_native_artifact_publication");
const Input = std.meta.Child(rule.Input);
const SignatureRow = std.meta.Child(@typeInfo(@FieldType(Input, "signature_shape")).optional.child);

pub fn artifact(allocator: std.mem.Allocator, value: anytype, entry: Native, fingerprint: [32]u8) std.mem.Allocator.Error!Artifact.Module {
    const types = try @import("../../../analysis/type_table.zig").copy(allocator, zx.columns.view(ir.TypeTable, value.types));
    const exports = try allocator.alloc(ir.Export, value.exports.len);
    const bindings = try allocator.alloc(FunctionImport, value.members.len);
    const writable = FunctionImport.Writable.borrowRows(bindings);
    const export_rows = zx.memory.borrowNamedRows("type_id", exports);
    var signatures: ir.SignatureStorage = .{};

    inline for (@typeInfo(ir.SignatureStorage).@"struct".field_names) |name| {
        try @field(signatures, name).ensureTotalCapacityPrecise(allocator, value.members.len);
    }

    const slots = zx.memory.bindColumnSet(SignatureRow, true, &signatures);
    const target: zx.memory.ColumnSet = &slots;
    const ExportRows = @FieldType(Input, "exports");
    const Members = @FieldType(Input, "members");
    const borrowed_origins = zx.columns.view(std.meta.Child(@FieldType(Input, "origins")), value.origins);

    const input: Input = .{
        .key = entry.key(),
        .declaration = &.{ .identity = entry.identity, .specifier = entry.specifier, .import_name = entry.module, .path = entry.path, .namespace = entry.namespace },
        .labels = types.labels,
        .origins = &borrowed_origins,
        .exports = zx.columns.slice(ExportRows, value.exports),
        .members = zx.columns.slice(Members, value.members),
        .signature_target = @ptrCast(&target),
        .signature_shape = null,
        .binding_target = &writable.view(std.meta.Child(@FieldType(Input, "binding_target"))),
        .export_target = @ptrCast(&export_rows),
    };

    const published = rule.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .path = published.path,
        .source_digest = fingerprint,
        .types = types,
        .nominal_types = columns.view(Origins.Table, published.origins),
        .exports = exports,
        .function_imports = bindings,
        .functions = signatures.view(),
        .native_modules = columns.view(ir.NativeModuleTable, published.modules),
        .dependencies = &.{},
        .type_imports = &.{},
        .function = null,
        .stores = .{},
    };
}
