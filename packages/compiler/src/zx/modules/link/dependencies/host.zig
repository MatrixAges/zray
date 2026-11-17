const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Builder = @import("../build.zig");
const Constants = @import("../../../analysis/constants/columns.zig").Rows;
const BindingColumns = @import("bindings/view.zig").Columns;
const Edges = @import("traversal/view.zig").Columns;
const generated = @import("generated_artifact_dependencies");
const Input = std.meta.Child(generated.Input);
const Checks = std.meta.Child(@FieldType(Input, "checks"));
const Imports = std.meta.Child(@FieldType(Input, "imports"));
const Tables = std.meta.Child(@typeInfo(@FieldType(Input, "providers")).optional.child);
const Bindings = std.meta.Child(@FieldType(Checks, "imports"));
const Aliases = std.meta.Child(@FieldType(Input, "aliases"));
const ConstantView = std.meta.Child(@FieldType(Input, "constants"));
const Signatures = std.meta.Child(@FieldType(Checks, "linked"));
const Ownership = ir.SymbolTable.Ownership;
const Export = ir.Export;

pub fn verify(self: *Builder, index: usize, functions: []const ?ir.FunctionId) Builder.Error!void {
    comptime std.debug.assert(@sizeOf(Ownership) == @sizeOf(u8));

    const module = &self.modules[index];
    const imports = BindingColumns.borrow(module.function_imports);
    const members = BindingColumns.borrow(module.members);
    const consumer_constants = Constants.borrow(module.constant_imports);
    const alias_names = memory.borrowTextColumn("name", module.type_imports);
    const alias_ids = memory.borrowReadColumn(ir.TypeId, "type_id", module.type_imports);
    const linked = self.functions.view();
    const targets = self.plan.sources(index);
    const dependencies = module.dependencies;
    const edges = Edges.borrow(dependencies, targets);
    const specifiers = memory.borrowTextColumn("specifier", dependencies);
    const dependency_names = memory.borrowReadColumn([]const []const u8, "names", dependencies);
    const source_names = memory.borrowReadColumn([]const []const u8, "source_names", dependencies);
    const exported = memory.borrowReadColumn(bool, "exported", dependencies);
    const wildcard = memory.borrowReadColumn(bool, "wildcard", dependencies);

    const checks: Checks = .{
        .count = module.functions.count(),
        .functions = @ptrCast(functions),
        .imports = &imports.view(Bindings),
        .members = &members.view(Bindings),
        .linked = &Signatures{
            .files = linked.files,
            .input_types = linked.input_types,
            .output_types = linked.output_types,
            .ownership = std.mem.sliceAsBytes(linked.ownership),
        },
        .types = @ptrCast(self.type_mappings[index]),
    };

    const input: Input = .{
        .checks = &checks,
        .aliases = &Aliases{ .names = @ptrCast(&alias_names), .ids = @ptrCast(&alias_ids), .count = alias_names.count },
        .constants = &consumer_constants.view(ConstantView),
        .imports = &Imports{
            .edges = &edges.view(std.meta.Child(@FieldType(Imports, "edges"))),
            .specifiers = @ptrCast(&specifiers),
            .names = @ptrCast(&dependency_names),
            .source_names = @ptrCast(&source_names),
            .exported = @ptrCast(&exported),
            .wildcard = @ptrCast(&wildcard),
        },
        .providers = null,
        .native_specifiers = module.native_modules.specifiers,
        .intrinsic_name = @import("../../intrinsic.zig").specifier,
    };

    if (targets.len == 0) return run(self.temporary, &input);

    return verifySources(self, &input);
}

const Field = enum {
    member_names,
    member_namespaces,
    member_ids,
    member_inputs,
    member_outputs,
    member_intrinsics,
    alias_names,
    alias_ids,
    constant_names,
    constant_types,
    constant_values,
    function_files,
    function_inputs,
    function_outputs,
    function_ownership,
    type_kinds,
};

const Projection = std.enums.EnumArray(Field, memory.ReadColumn);

fn verifySources(self: *Builder, input: *const Input) Builder.Error!void {
    const modules = self.modules;

    const sources = std.enums.EnumArray(Field, memory.ListColumn).init(.{
        .member_names = memory.borrowListColumn([]const u8, "members", "name", modules),
        .member_namespaces = memory.borrowListColumn(?[]const u8, "members", "namespace", modules),
        .member_ids = memory.borrowListColumn(?u32, "members", "id", modules),
        .member_inputs = memory.borrowListColumn(?u32, "members", "input_type", modules),
        .member_outputs = memory.borrowListColumn(?u32, "members", "output_type", modules),
        .member_intrinsics = memory.borrowListColumn(?u8, "members", "intrinsic", modules),
        .alias_names = memory.borrowListColumn([]const u8, "exports", "name", modules),
        .alias_ids = memory.borrowListColumn(@FieldType(Export, "type_id"), "exports", "type_id", modules),
        .constant_names = memory.borrowListColumn([]const u8, "constant_exports", "name", modules),
        .constant_types = memory.borrowListColumn(ir.TypeId, "constant_exports", "type_id", modules),
        .constant_values = memory.borrowListColumn(ir.ConstantValue, "constant_exports", "value", modules),
        .function_files = memory.borrowSliceColumn(&.{ "functions", "files" }, modules),
        .function_inputs = memory.borrowSliceColumn(&.{ "functions", "input_types" }, modules),
        .function_outputs = memory.borrowSliceColumn(&.{ "functions", "output_types" }, modules),
        .function_ownership = memory.borrowSliceColumn(&.{ "functions", "ownership" }, modules),
        .type_kinds = memory.borrowSliceColumn(&.{ "types", "kinds" }, modules),
    });

    var target: Projection = undefined;
    const projection: memory.ListProjection = .{ .sources = &sources.values, .target = &target.values };

    const tables: Tables = .{
        .projection = @ptrCast(&projection),
        .members = &.{
            .names = @ptrCast(target.getPtr(.member_names)),
            .namespaces = @ptrCast(target.getPtr(.member_namespaces)),
            .ids = @ptrCast(target.getPtr(.member_ids)),
            .inputs = @ptrCast(target.getPtr(.member_inputs)),
            .outputs = @ptrCast(target.getPtr(.member_outputs)),
            .intrinsics = @ptrCast(target.getPtr(.member_intrinsics)),
        },
        .signatures = &.{
            .files = @ptrCast(target.getPtr(.function_files)),
            .input_types = @ptrCast(target.getPtr(.function_inputs)),
            .output_types = @ptrCast(target.getPtr(.function_outputs)),
            .ownership = @ptrCast(target.getPtr(.function_ownership)),
        },
        .aliases = &.{
            .names = @ptrCast(target.getPtr(.alias_names)),
            .ids = @ptrCast(target.getPtr(.alias_ids)),
        },
        .constants = &.{
            .names = @ptrCast(target.getPtr(.constant_names)),
            .types = @ptrCast(target.getPtr(.constant_types)),
            .values = @ptrCast(target.getPtr(.constant_values)),
        },
        .kinds = @ptrCast(target.getPtr(.type_kinds)),
        .types = @ptrCast(self.type_mappings),
        .functions = @ptrCast(self.module_functions),
    };

    var request = input.*;

    request.providers = &tables;

    return run(self.temporary, &request);
}

fn run(temporary: std.mem.Allocator, request: *const Input) Builder.Error!void {
    const status = zx.columns.invoke(generated.executeValue, temporary, request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Ready => {},
        .Invalid => error.InvalidModule,
        .Conflict => error.ConflictingInterface,
    };
}
