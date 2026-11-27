const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../artifact/model.zig");
const Native = @import("../../interface.zig").Native;
const FunctionImport = @import("../../function_import.zig");
const Current = @import("../native_restore.zig").Current;
const Origins = @import("../../nominal_origins.zig");
const borrow = @import("../../../ir/canonical/borrow.zig");
const names = @import("../../../ir/canonical/validation/names/view.zig");
const Input = std.meta.Child(@import("generated_native_restore").Input);
const Validation = std.meta.Child(@FieldType(Input, "validation"));
const Request = std.meta.Child(@FieldType(Validation, "request"));
const Admission = std.meta.Child(@typeInfo(@FieldType(Input, "admission")).optional.child);
const Ports = std.meta.Child(@FieldType(Admission, "ports"));
const Self = @This();

signatures: std.meta.Child(@FieldType(Request, "signatures")),
modules: std.meta.Child(@FieldType(Request, "modules")),
origins: std.meta.Child(@FieldType(Request, "origins")),
declaration: std.meta.Child(@FieldType(Request, "declaration")),
types: std.meta.Child(@FieldType(Validation, "types")),
base: std.meta.Child(@FieldType(Input, "base")),
base_origins: std.meta.Child(@FieldType(Input, "base_origins")),
export_rows: names.Rows,
exports: std.meta.Child(@FieldType(Request, "exports")),
request: Request,
validation: Validation,
type_ids: []u32,
ports: FunctionImport.Readable,
binding_names: zx.memory.TextColumn,
namespaces: zx.memory.ReadColumn,
port_rows: Ports,
admission: Admission,
input: Input,
pub fn init(self: *Self, artifact: *const Artifact.Module, entry: Native, current: Current, admitted: bool, type_ids: []u32) void {
    self.signatures = borrow.columns(@TypeOf(self.signatures), artifact.functions);
    self.modules = borrow.columns(@TypeOf(self.modules), artifact.native_modules);
    self.origins = Origins.Table.borrow(@TypeOf(self.origins), artifact.nominal_types);
    self.declaration = .{ .identity = entry.identity, .specifier = entry.specifier, .path = entry.path, .import_name = entry.module, .namespace = entry.namespace };
    self.types = ir.TypeTable.borrow(@TypeOf(self.types), artifact.types);
    self.base = ir.TypeTable.borrow(@TypeOf(self.base), current.types.view());
    self.base_origins = Origins.Table.borrow(@TypeOf(self.base_origins), current.origins.items.view());
    self.export_rows = names.borrow(artifact.exports);
    self.exports = names.view(@TypeOf(self.exports), &self.export_rows);

    self.request = .{
        .path = artifact.path,
        .has_function = artifact.function != null,
        .dependency_count = artifact.dependencies.len,
        .type_import_count = artifact.type_imports.len,
        .constant_export_count = artifact.constant_exports.len,
        .constant_import_count = artifact.constant_imports.len,
        .store_count = artifact.stores.count(),
        .signatures = &self.signatures,
        .modules = &self.modules,
        .exports = &self.exports,
        .origins = &self.origins,
        .import_count = artifact.function_imports.len,
        .declaration = &self.declaration,
    };

    self.validation = .{
        .request = &self.request,
        .types = &self.types,
        .scalar_count = std.enums.values(ir.Scalar).len,
        .maximum_count = std.math.maxInt(u32),
    };

    self.type_ids = type_ids;

    if (!admitted) {
        self.ports = FunctionImport.Readable.borrowRows(artifact.function_imports);
        self.binding_names = zx.memory.borrowTextColumn("name", artifact.function_imports);
        self.namespaces = zx.memory.borrowReadColumn(?[]const u8, "namespace", artifact.function_imports);
        self.port_rows = self.ports.view(Ports);

        self.admission = .{
            .ports = &self.port_rows,
            .names = @ptrCast(&self.binding_names),
            .namespaces = @ptrCast(&self.namespaces),
        };
    }

    self.input = .{
        .validation = &self.validation,
        .origin_names = artifact.nominal_types.names,
        .base = &self.base,
        .base_origins = &self.base_origins,
        .mapping = @ptrCast(&self.type_ids),
        .type_ids = self.type_ids,
        .admission = if (admitted) null else &self.admission,
    };
}
