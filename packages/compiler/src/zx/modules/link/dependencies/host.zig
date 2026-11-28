const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Builder = @import("../build.zig");
const Constants = @import("../../../analysis/constants/columns.zig").Rows;
const member_fields = @import("../../function_import.zig").member_fields;
const BindingColumns = memory.ReadFields(member_fields);
const Edges = @import("traversal/view.zig").Columns;
pub const Binding = @import("../artifact/binding/abi.zig").Binding;
const Input = std.meta.Child(@FieldType(Binding, "dependencies"));
const Walk = std.meta.Child(@FieldType(Input, "walk"));
const Checks = std.meta.Child(@FieldType(Walk, "checks"));
const Imports = std.meta.Child(@FieldType(Walk, "imports"));
const Tables = std.meta.Child(@typeInfo(@FieldType(Walk, "providers")).optional.child);
const Bindings = std.meta.Child(@FieldType(Checks, "imports"));
const Aliases = std.meta.Child(@FieldType(Walk, "aliases"));
const ConstantView = std.meta.Child(@FieldType(Walk, "constants"));
const Signatures = std.meta.Child(@FieldType(Checks, "linked"));
const Ownership = ir.SymbolTable.Ownership;
const Export = ir.Export;
const alias_fields = .{ .names = "name", .ids = "type_id" };
const import_fields = .{ .specifiers = "specifier", .names = "names", .source_names = "source_names", .exported = "exported", .wildcard = "wildcard" };

pub const View = struct {
    input: Input,
    checks: Checks,
    walk: Walk,
    imports: Imports,
    import_columns: BindingColumns,
    member_columns: BindingColumns,
    imported: Bindings,
    members: Bindings,
    constant_columns: Constants,
    constants: ConstantView,
    alias_columns: memory.ReadFields(alias_fields),
    aliases: Aliases,
    linked: Signatures,
    edge_columns: Edges,
    edges: std.meta.Child(@FieldType(Imports, "edges")),
    dependency_columns: memory.ReadFields(import_fields),
    pub fn init(self: *View, builder: *Builder, index: usize, sources: *const Providers) void {
        comptime std.debug.assert(@sizeOf(Ownership) == @sizeOf(u8));

        const module = &builder.modules[index];
        const targets = builder.plan.sources(index);
        const dependencies = module.dependencies;

        self.import_columns = memory.borrowReadFields(member_fields, module.function_imports);
        self.member_columns = memory.borrowReadFields(member_fields, module.members);
        self.imported = self.import_columns.bind(Bindings);
        self.members = self.member_columns.bind(Bindings);
        self.constant_columns = Constants.borrow(module.constant_imports);
        self.constants = self.constant_columns.view(ConstantView);
        self.alias_columns = memory.borrowReadFields(alias_fields, module.type_imports);
        self.aliases = self.alias_columns.bind(Aliases);

        self.refreshLinked(&builder.functions);

        self.edge_columns = Edges.borrow(dependencies, targets);
        self.edges = self.edge_columns.view(@FieldType(View, "edges"));
        self.dependency_columns = memory.borrowReadFields(import_fields, dependencies);

        self.dependency_columns.fill(&self.imports);

        self.imports.edges = &self.edges;

        self.checks = .{
            .count = module.functions.count(),
            .imports = &self.imported,
            .members = &self.members,
            .types = @ptrCast(builder.type_mappings[index]),
            .linked = &self.linked,
            .functions = &.{},
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

        self.input = .{ .walk = &self.walk };
    }
    pub fn refreshLinked(self: *View, functions: *const ir.FunctionStorage) void {
        const source = functions.view();

        self.linked = .{
            .files = source.files,
            .input_types = source.input_types,
            .output_types = source.output_types,
            .ownership = std.mem.sliceAsBytes(source.ownership),
        };
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

pub const Providers = struct {
    sources: Sources,
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

        self.members = .{
            .names = @ptrCast(self.sources.getPtrConst(.member_names)),
            .namespaces = @ptrCast(self.sources.getPtrConst(.member_namespaces)),
            .ids = @ptrCast(self.sources.getPtrConst(.member_ids)),
            .inputs = @ptrCast(self.sources.getPtrConst(.member_inputs)),
            .outputs = @ptrCast(self.sources.getPtrConst(.member_outputs)),
            .intrinsics = @ptrCast(self.sources.getPtrConst(.member_intrinsics)),
        };

        self.signatures = .{
            .files = @ptrCast(self.sources.getPtrConst(.function_files)),
            .input_types = @ptrCast(self.sources.getPtrConst(.function_inputs)),
            .output_types = @ptrCast(self.sources.getPtrConst(.function_outputs)),
            .ownership = @ptrCast(self.sources.getPtrConst(.function_ownership)),
        };

        self.aliases = .{
            .names = @ptrCast(self.sources.getPtrConst(.alias_names)),
            .ids = @ptrCast(self.sources.getPtrConst(.alias_ids)),
        };

        self.constants = .{
            .names = @ptrCast(self.sources.getPtrConst(.constant_names)),
            .types = @ptrCast(self.sources.getPtrConst(.constant_types)),
            .values = @ptrCast(self.sources.getPtrConst(.constant_values)),
        };

        self.tables = .{
            .members = &self.members,
            .signatures = &self.signatures,
            .aliases = &self.aliases,
            .constants = &self.constants,
            .kinds = @ptrCast(self.sources.getPtrConst(.type_kinds)),
            .types = @ptrCast(builder.type_mappings),
            .functions = @ptrCast(builder.module_functions),
        };
    }
};
