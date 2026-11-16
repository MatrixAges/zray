const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const FunctionImport = @import("../../../function_import.zig");
const Current = @import("../../restore.zig").Current;
const imports = @import("../imports.zig");
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const generated = @import("generated_semantic_restore_rebind");
const Input = std.meta.Child(generated.Input);
const Aliases = std.meta.Child(@FieldType(Input, "aliases"));
const Bindings = std.meta.Child(@FieldType(Input, "bindings"));
const Binding = std.meta.Child(std.meta.Elem(@FieldType(Bindings, "previous")));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Modules = std.meta.Child(@FieldType(Input, "modules"));
const Entry = std.meta.Child(@FieldType(Input, "entry"));

pub const Maps = struct {
    types: []const ir.TypeId,
    functions: []?ir.FunctionId,
    natives: []?ir.NativeModuleId,
};

pub fn check(temporary: std.mem.Allocator, module: *const Artifact.Module, current: *const Current, maps: Maps) Artifact.Error!?ir.FunctionId {
    const function_count = module.functions.count();
    const linked_count = current.functions.count();
    const linked = ir.SignatureTable.fromFunctions(current.functions.view());
    const types: []const u32 = @ptrCast(maps.types);
    const functions = maps.functions[0..function_count];
    const SignatureTable = std.meta.Child(@FieldType(Signatures, "previous"));
    const NativeTable = std.meta.Child(@FieldType(Modules, "previous"));
    const previous_signatures = zx.columns.columns(SignatureTable, module.functions);
    const current_signatures = zx.columns.columns(SignatureTable, linked);
    const previous_modules = zx.columns.columns(NativeTable, module.native_modules);
    const current_modules = zx.columns.columns(NativeTable, current.native_modules);

    const signatures: Signatures = .{
        .previous = &previous_signatures,
        .current = &current_signatures,
        .types = types,
        .functions = @ptrCast(functions),
        .modules = @ptrCast(maps.natives),
    };

    const modules: Modules = .{
        .previous = &previous_modules,
        .current = &current_modules,
        .types = types,
        .target = @ptrCast(&maps.natives),
    };

    const entry: Entry = .{
        .has_body = module.function != null,
        .local_count = function_count,
        .linked_count = linked_count,
        .target = @ptrCast(&maps.functions),
    };

    const AliasRows = std.meta.Child(@FieldType(Aliases, "previous"));
    const previous_aliases = names.borrow(module.type_imports);
    const current_aliases = names.borrow(current.aliases);
    const previous_names = names.view(AliasRows, &previous_aliases);
    const current_names = names.view(AliasRows, &current_aliases);
    const alias_view: Aliases = .{ .previous = &previous_names, .current = &current_names, .types = types };
    var bindings: imports.Batch(Binding) = undefined;
    var binding_offset: usize = 0;
    var member_offset: usize = 0;
    var first = true;

    while (true) {
        const imported = @min(imports.batch_size, current.imports.len - binding_offset);
        const forwarded = @min(imports.batch_size - imported, current.members.len - member_offset);
        const import_end = binding_offset + imported;
        const member_end = member_offset + forwarded;

        bindings.write(0, module.function_imports[binding_offset..import_end], current.imports[binding_offset..import_end], binding);
        bindings.write(imported, module.members[member_offset..member_end], current.members[member_offset..member_end], binding);

        const binding_rows = bindings.rows(imported + forwarded);
        const finish = import_end == current.imports.len and member_end == current.members.len;

        const binding_view: Bindings = .{
            .previous = binding_rows.previous,
            .current = binding_rows.current,
            .mapping = @ptrCast(functions),
            .target = @ptrCast(&functions),
            .types = types,
            .current_count = linked_count,
        };

        const input: Input = .{
            .aliases = &alias_view,
            .modules = &modules,
            .bindings = &binding_view,
            .signatures = &signatures,
            .entry = &entry,
            .first = first,
            .finish = finish,
        };

        const status = zx.columns.invoke(generated.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        switch (status) {
            .Invalid => return error.InvalidModule,
            .Full => return error.OutOfMemory,
            .Ready => {},
        }

        if (finish) return if (entry.has_body) maps.functions[function_count] else null;

        first = false;
        binding_offset = import_end;
        member_offset = member_end;
    }
}

fn binding(comptime Row: type, value: *const FunctionImport) Row {
    return value.borrow(Row);
}
