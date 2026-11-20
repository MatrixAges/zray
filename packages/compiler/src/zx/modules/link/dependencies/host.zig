const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Builder = @import("../build.zig");
const Constants = @import("../../../analysis/constants/columns.zig").Rows;
const BindingColumns = @import("bindings/view.zig").Columns;
const Edges = @import("traversal/view.zig").Columns;
const admission = @import("../artifact/admission/host.zig");
pub const Binding = @import("../artifact/binding/abi.zig").Binding;
const Input = std.meta.Child(@FieldType(Binding, "dependencies"));
const Walk = std.meta.Child(@FieldType(Input, "walk"));
const Views = std.meta.Child(@FieldType(Input, "views"));
const Checks = std.meta.Child(@FieldType(Walk, "checks"));
const Imports = std.meta.Child(@FieldType(Walk, "imports"));
const Tables = std.meta.Child(@typeInfo(@FieldType(Walk, "providers")).optional.child);
const Bindings = std.meta.Child(@FieldType(Checks, "imports"));
const Aliases = std.meta.Child(@FieldType(Walk, "aliases"));
const ConstantView = std.meta.Child(@FieldType(Walk, "constants"));
const Signatures = std.meta.Child(@typeInfo(@FieldType(Views, "linked_shape")).optional.child);
const Ownership = ir.SymbolTable.Ownership;
const Export = ir.Export;

pub const View = struct {
    input: Input,
    checks: Checks,
    walk: Walk,
    views: Views,
    imports: Imports,
    import_columns: BindingColumns,
    member_columns: BindingColumns,
    imported: Bindings,
    members: Bindings,
    constant_columns: Constants,
    constants: ConstantView,
    alias_names: memory.ReadColumn,
    alias_ids: memory.ReadColumn,
    aliases: Aliases,
    linked_slots: [@typeInfo(Signatures).@"struct".field_names.len]*anyopaque,
    linked_columns: memory.ColumnSet,
    linked: Signatures,
    edge_columns: Edges,
    edges: std.meta.Child(@FieldType(Imports, "edges")),
    specifiers: memory.ReadColumn,
    names: memory.ReadColumn,
    source_names: memory.ReadColumn,
    exported: memory.ReadColumn,
    wildcard: memory.ReadColumn,
    pub fn init(self: *View, builder: *Builder, index: usize, mappings: *admission.Mappings, sources: *const Providers) void {
        comptime std.debug.assert(@sizeOf(Ownership) == @sizeOf(u8));

        const module = &builder.modules[index];
        const targets = builder.plan.sources(index);
        const dependencies = module.dependencies;

        self.import_columns = BindingColumns.borrow(module.function_imports);
        self.member_columns = BindingColumns.borrow(module.members);
        self.imported = self.import_columns.view(Bindings);
        self.members = self.member_columns.view(Bindings);
        self.constant_columns = Constants.borrow(module.constant_imports);
        self.constants = self.constant_columns.view(ConstantView);
        self.alias_names = memory.borrowTextColumn("name", module.type_imports);
        self.alias_ids = memory.borrowReadColumn(ir.TypeId, "type_id", module.type_imports);

        self.aliases = .{
            .names = @ptrCast(&self.alias_names),
            .ids = @ptrCast(&self.alias_ids),
            .count = self.alias_names.count,
        };

        self.linked_slots = memory.bindColumnSet(Signatures, false, &builder.functions);
        self.linked_columns = &self.linked_slots;
        self.edge_columns = Edges.borrow(dependencies, targets);
        self.edges = self.edge_columns.view(@FieldType(View, "edges"));
        self.specifiers = memory.borrowTextColumn("specifier", dependencies);
        self.names = memory.borrowReadColumn([]const []const u8, "names", dependencies);
        self.source_names = memory.borrowReadColumn([]const []const u8, "source_names", dependencies);
        self.exported = memory.borrowReadColumn(bool, "exported", dependencies);
        self.wildcard = memory.borrowReadColumn(bool, "wildcard", dependencies);

        self.imports = .{
            .edges = &self.edges,
            .specifiers = @ptrCast(&self.specifiers),
            .names = @ptrCast(&self.names),
            .source_names = @ptrCast(&self.source_names),
            .exported = @ptrCast(&self.exported),
            .wildcard = @ptrCast(&self.wildcard),
        };

        self.checks = .{
            .count = module.functions.count(),
            .imports = &self.imported,
            .members = &self.members,
            .types = @ptrCast(builder.type_mappings[index]),
            .linked = &self.linked,
            .functions = &.{},
        };

        self.views = .{
            .mapping = @ptrCast(&mappings.functions),
            .functions = @ptrCast(&self.checks.functions),
            .linked_columns = @ptrCast(&self.linked_columns),
            .linked_view = @ptrCast(&self.linked),
            .linked_shape = null,
        };

        self.walk = .{
            .checks = &self.checks,
            .aliases = &self.aliases,
            .constants = &self.constants,
            .imports = &self.imports,
            .providers = if (targets.len != 0) &sources.tables else null,
            .native_specifiers = module.native_modules.specifiers,
            .intrinsic_name = @import("../../intrinsic.zig").specifier,
        };

        self.input = .{ .walk = &self.walk, .views = &self.views };
    }
};

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

const Sources = std.enums.EnumArray(Field, memory.ListColumn);
const Projection = std.enums.EnumArray(Field, memory.ReadColumn);

pub const Providers = struct {
    sources: Sources,
    target: Projection,
    projection: memory.ListProjection,
    tables: Tables,
    members: std.meta.Child(@FieldType(Tables, "members")),
    signatures: std.meta.Child(@FieldType(Tables, "signatures")),
    aliases: std.meta.Child(@FieldType(Tables, "aliases")),
    constants: std.meta.Child(@FieldType(Tables, "constants")),
    pub fn signature(self: *const Providers, comptime Shape: type, paths: []const []const u8) Shape {
        return .{
            .paths = paths,
            .files = @ptrCast(&self.sources.getPtrConst(.function_files).lists),
            .ids = @ptrCast(self.sources.getPtrConst(.member_ids)),
            .inputs = @ptrCast(self.sources.getPtrConst(.member_inputs)),
            .outputs = @ptrCast(self.sources.getPtrConst(.member_outputs)),
            .intrinsics = @ptrCast(self.sources.getPtrConst(.member_intrinsics)),
        };
    }
    pub fn init(self: *Providers, builder: *const Builder) void {
        const modules = builder.modules;

        self.sources = Sources.init(.{
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

        self.projection = .{ .sources = &self.sources.values, .target = &self.target.values };

        self.members = .{
            .names = @ptrCast(self.target.getPtr(.member_names)),
            .namespaces = @ptrCast(self.target.getPtr(.member_namespaces)),
            .ids = @ptrCast(self.target.getPtr(.member_ids)),
            .inputs = @ptrCast(self.target.getPtr(.member_inputs)),
            .outputs = @ptrCast(self.target.getPtr(.member_outputs)),
            .intrinsics = @ptrCast(self.target.getPtr(.member_intrinsics)),
        };

        self.signatures = .{
            .files = @ptrCast(self.target.getPtr(.function_files)),
            .input_types = @ptrCast(self.target.getPtr(.function_inputs)),
            .output_types = @ptrCast(self.target.getPtr(.function_outputs)),
            .ownership = @ptrCast(self.target.getPtr(.function_ownership)),
        };

        self.aliases = .{
            .names = @ptrCast(self.target.getPtr(.alias_names)),
            .ids = @ptrCast(self.target.getPtr(.alias_ids)),
        };

        self.constants = .{
            .names = @ptrCast(self.target.getPtr(.constant_names)),
            .types = @ptrCast(self.target.getPtr(.constant_types)),
            .values = @ptrCast(self.target.getPtr(.constant_values)),
        };

        self.tables = .{
            .projection = @ptrCast(&self.projection),
            .members = &self.members,
            .signatures = &self.signatures,
            .aliases = &self.aliases,
            .constants = &self.constants,
            .kinds = @ptrCast(self.target.getPtr(.type_kinds)),
            .types = @ptrCast(builder.type_mappings),
            .functions = @ptrCast(builder.module_functions),
        };
    }
};
