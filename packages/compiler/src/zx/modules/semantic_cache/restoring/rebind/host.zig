const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const FunctionImport = @import("../../../function_import.zig");
const Current = @import("../../restore.zig").Current;
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const generated = @import("generated_semantic_restore_transaction");
const Transaction = std.meta.Child(generated.Input);
const Input = std.meta.Child(@FieldType(Transaction, "rebind"));
const Output = @typeInfo(@TypeOf(generated.executeValue(undefined, undefined))).error_union.payload;
pub const TypeRequest = std.meta.Child(@FieldType(Transaction, "types"));
pub const TypePlan = @typeInfo(@FieldType(Output, "plan")).optional.child;
const Aliases = std.meta.Child(@FieldType(Input, "aliases"));
const Bindings = std.meta.Child(@FieldType(Input, "bindings"));
const Columns = FunctionImport.Columns;
const BindingColumns = std.meta.Child(@FieldType(Bindings, "previous"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Modules = std.meta.Child(@FieldType(Input, "modules"));
const Buffers = std.meta.Child(@FieldType(Transaction, "buffers"));

pub const Maps = struct {
    allocator: std.mem.Allocator,
    types: []u32 = &.{},
    functions: []?ir.FunctionId = &.{},
    natives: []?ir.NativeModuleId = &.{},
    fn view(self: *Maps) Buffers {
        return .{
            .allocator = @ptrCast(&self.allocator),
            .types = @ptrCast(&self.types),
            .functions = @ptrCast(&self.functions),
            .modules = @ptrCast(&self.natives),
        };
    }
};

pub const Prepared = struct { types: TypePlan, entry: ?ir.FunctionId };

pub fn prepare(temporary: std.mem.Allocator, module: *const Artifact.Module, current: *const Current, maps: *Maps, types_request: *const TypeRequest) Artifact.Error!Prepared {
    const linked = ir.SignatureTable.fromFunctions(current.functions.view());
    const SignatureTable = std.meta.Child(@FieldType(Signatures, "previous"));
    const NativeTable = std.meta.Child(@FieldType(Modules, "previous"));
    const previous_signatures = zx.columns.columns(SignatureTable, module.functions);
    const current_signatures = zx.columns.columns(SignatureTable, linked);
    const previous_modules = zx.columns.columns(NativeTable, module.native_modules);
    const current_modules = zx.columns.columns(NativeTable, current.native_modules);
    const AliasRows = std.meta.Child(@FieldType(Aliases, "previous"));
    const previous_aliases = names.borrow(module.type_imports);
    const current_aliases = names.borrow(current.aliases);
    const previous_names = names.view(AliasRows, &previous_aliases);
    const current_names = names.view(AliasRows, &current_aliases);
    const old_imports = Columns.borrow(module.function_imports);
    const new_imports = Columns.borrow(current.imports);
    const old_members = Columns.borrow(module.members);
    const new_members = Columns.borrow(current.members);
    const old_bindings = old_imports.view(BindingColumns);
    const new_bindings = new_imports.view(BindingColumns);
    const old_exports = old_members.view(BindingColumns);
    const new_exports = new_members.view(BindingColumns);

    const input: Input = .{
        .aliases = &.{ .previous = &previous_names, .current = &current_names },
        .modules = &.{ .previous = &previous_modules, .current = &current_modules },
        .bindings = &.{ .previous = &old_bindings, .current = &new_bindings },
        .members = &.{ .previous = &old_exports, .current = &new_exports },
        .signatures = &.{ .previous = &previous_signatures, .current = &current_signatures },
        .has_body = module.function != null,
        .linked_count = linked.count(),
    };

    const transaction: Transaction = .{ .types = types_request, .rebind = &input, .buffers = &maps.view() };

    const prepared = zx.columns.invoke(generated.executeValue, temporary, &transaction) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (prepared.status) {
        .Invalid => error.InvalidModule,
        .Full => error.OutOfMemory,
        .Ready => .{
            .types = prepared.plan.?,
            .entry = if (prepared.entry) |id| @fromBackingInt(id) else null,
        },
    };
}
