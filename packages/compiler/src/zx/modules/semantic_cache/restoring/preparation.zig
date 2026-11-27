const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../artifact/model.zig");
const FunctionImport = @import("../../function_import.zig");
const names = @import("../../../ir/canonical/validation/names/view.zig");
const Preflight = @import("preflight/host.zig");
const generated = @import("generated_semantic_restore");
const Transaction = std.meta.Child(@FieldType(std.meta.Child(generated.Input), "planning"));
const Input = std.meta.Child(@FieldType(Transaction, "rebind"));
const TypeRequest = std.meta.Child(@FieldType(Transaction, "types"));
const Aliases = std.meta.Child(@FieldType(Input, "aliases"));
const Bindings = std.meta.Child(@FieldType(Input, "bindings"));
const BindingColumns = std.meta.Child(@FieldType(Bindings, "previous"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Modules = std.meta.Child(@FieldType(Input, "modules"));
const Origins = @import("../../nominal_origins.zig");
const Merge = std.meta.Child(@FieldType(TypeRequest, "merge"));
const Table = std.meta.Child(@FieldType(Merge, "source"));
const Nominal = std.meta.Child(@FieldType(Merge, "origins"));
const Constants = std.meta.Child(@typeInfo(@FieldType(TypeRequest, "current_constants")).optional.child);
const marshal = @import("../../../analysis/constants/input.zig").marshal;
const scalar_rows = @import("../../../analysis/type_table.zig").scalar_rows;

pub fn execute(frame: *@import("run.zig").Frame) Artifact.Error!@import("../restore.zig").Restored {
    const temporary = frame.workspace;
    const module = frame.module;
    const current = frame.current;
    const decoded = frame.decoded;
    const current_types = current.types.view();
    const source = ir.TypeTable.borrow(Table, module.types);
    const destination = ir.TypeTable.borrow(Table, current_types);
    const base = ir.TypeTable.borrow(Table, if (current_types.count() == 0) scalar_rows else current_types);
    const empty = ir.TypeTable.borrow(Table, .{});
    const origins = Origins.Table.borrow(Nominal, module.nominal_types);
    const base_origins = Origins.Table.borrow(Nominal, current.origins.items.view());

    const merge: Merge = .{
        .source = &source,
        .origins = &origins,
        .names = module.nominal_types.names,
        .base = &base,
        .base_origins = &base_origins,
    };

    const types_request: TypeRequest = .{
        .merge = &merge,
        .current_types = &destination,
        .empty = &empty,
        .current_constants = try marshal(Constants, temporary, current.constant_imports),
        .cached_constants = try marshal(Constants, temporary, module.constant_imports),
        .cached_exports = if (decoded) null else try marshal(Constants, temporary, module.constant_exports),
        .scalar_count = scalar_rows.count(),
        .maximum_count = std.math.maxInt(u32),
        .decoded = decoded,
    };

    const SignatureTable = std.meta.Child(@FieldType(Signatures, "previous"));
    const NativeTable = std.meta.Child(@FieldType(Modules, "previous"));
    const previous_signatures = ir.SignatureTable.borrow(SignatureTable, &module.functions);
    const current_signatures = ir.SignatureTable.borrow(SignatureTable, current.functions);
    const previous_modules = zx.columns.columns(NativeTable, module.native_modules);
    const current_modules = zx.columns.columns(NativeTable, current.native_modules);
    const AliasRows = std.meta.Child(@FieldType(Aliases, "previous"));
    const previous_aliases = names.borrow(module.type_imports);
    const current_aliases = names.borrow(current.aliases);
    const previous_names = names.view(AliasRows, &previous_aliases);
    const current_names = names.view(AliasRows, &current_aliases);
    const old_imports = FunctionImport.borrowColumns(module.function_imports);
    const new_imports = FunctionImport.borrowColumns(current.imports);
    const old_members = FunctionImport.borrowColumns(module.members);
    const new_members = FunctionImport.borrowColumns(current.members);

    const input: Input = .{
        .aliases = &.{ .previous = &previous_names, .current = &current_names },
        .modules = &.{ .previous = &previous_modules, .current = &current_modules },
        .bindings = &.{ .previous = &old_imports.bind(BindingColumns), .current = &new_imports.bind(BindingColumns) },
        .members = &.{ .previous = &old_members.bind(BindingColumns), .current = &new_members.bind(BindingColumns) },
        .signatures = &.{ .previous = &previous_signatures, .current = &current_signatures },
        .has_body = module.function != null,
        .linked_count = current.functions.count(),
    };

    var preflight: Preflight = undefined;

    preflight.init(temporary, module, current, decoded, &previous_modules, &current_modules, &previous_signatures);

    const transaction: Transaction = .{
        .preflight = &preflight.input,
        .types = &types_request,
        .rebind = &input,
    };

    return frame.execute(&transaction);
}
