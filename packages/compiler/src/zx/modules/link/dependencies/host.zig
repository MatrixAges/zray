const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../build.zig");
const names = @import("../../../ir/canonical/validation/names/view.zig");
const Record = @import("../../module_record.zig");
const BindingColumns = @import("bindings/view.zig").Columns;
const Constants = @import("../../../analysis/constants/columns.zig").Rows;
const Edges = @import("traversal/view.zig").Columns;
const generated = @import("generated_artifact_dependencies");
const Input = std.meta.Child(generated.Input);
const Checks = child("checks");
const Edge = child("edge");
const Walk = std.meta.Child(@FieldType(Input, "walk"));
const Cursor = std.meta.Child(@FieldType(Walk, "cursor"));
const Provider = std.meta.Child(@FieldType(Edge, "provider"));
const Consumer = std.meta.Child(@FieldType(Edge, "consumer"));
const Dependency = std.meta.Child(@FieldType(Edge, "dependency"));
const Bindings = std.meta.Child(@FieldType(Checks, "imports"));
const Aliases = std.meta.Child(@FieldType(Provider, "aliases"));
const ConstantView = std.meta.Child(@FieldType(Provider, "constants"));
const Signatures = std.meta.Child(@FieldType(Checks, "linked"));

fn child(comptime name: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(Input, name)).optional.child);
}

pub fn verify(self: *Builder, index: usize, functions: []const ?ir.FunctionId) Builder.Error!void {
    const module = &self.modules[index];
    const imports = BindingColumns.borrow(module.function_imports);
    const members = BindingColumns.borrow(module.members);
    const consumer_constants = Constants.borrow(module.constant_imports);
    const consumer_aliases = names.borrow(module.type_imports);
    const linked = signatures(ir.SignatureTable.fromFunctions(self.functions.view()));

    const binding_checks: Checks = .{
        .count = module.functions.count(),
        .functions = @ptrCast(functions),
        .imports = &imports.view(Bindings),
        .members = &members.view(Bindings),
        .linked = &linked,
        .types = @ptrCast(self.type_mappings[index]),
    };

    var consumer: Consumer = .{
        .members = binding_checks.imports,
        .aliases = &names.view(Aliases, &consumer_aliases),
        .constants = &consumer_constants.view(ConstantView),
        .types = binding_checks.types,
        .functions = binding_checks.functions,
    };

    const edges = Edges.borrow(module.dependencies, self.plan.sources(index));
    const specifiers = zx.memory.borrowTextColumn("specifier", module.dependencies);
    var cursor: Cursor = .{ .row = 0, .source = 0 };

    const walk: Walk = .{
        .cursor = &cursor,
        .edges = &edges.view(std.meta.Child(@FieldType(Walk, "edges"))),
        .specifiers = @ptrCast(&specifiers),
        .native_specifiers = module.native_modules.specifiers,
        .intrinsic_name = @import("../../intrinsic.zig").specifier,
    };

    var request: Input = .{ .checks = &binding_checks, .edge = null, .walk = &walk };
    var pending: SourceEdge = undefined;

    while (true) {
        const result = zx.columns.invoke(generated.executeValue, self.temporary, @as(*const Input, &request)) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        switch (result.status) {
            .Ready => {},
            .Invalid => return error.InvalidModule,
            .Conflict => return error.ConflictingInterface,
        }

        const target = result.target orelse return;
        const dependency = &module.dependencies[@intCast(result.row - 1)];
        const provider: usize = @intCast(target);
        consumer.members = if (dependency.exported) binding_checks.members else binding_checks.imports;

        pending.init(&self.modules[provider], self.type_mappings[provider], dependency, &consumer, &linked);

        cursor = .{ .row = result.row, .source = result.source };
        request.checks = null;
        request.edge = &pending.request;
    }
}

const SourceEdge = struct {
    aliases: names.Rows,
    constants: Constants,
    members: BindingColumns,
    member_view: Bindings,
    alias_view: Aliases,
    constant_view: ConstantView,
    provider_signatures: Signatures,
    provider: Provider,
    dependency: Dependency,
    request: Edge,
    fn init(self: *SourceEdge, module: *const @import("../../artifact/model.zig").Module, types: []const ir.TypeId, edge: *const Record.Import, consumer: *const Consumer, linked: *const Signatures) void {
        self.aliases = names.borrow(module.exports);
        self.constants = Constants.borrow(module.constant_exports);
        self.members = BindingColumns.borrow(module.members);
        self.member_view = self.members.view(Bindings);
        self.alias_view = names.view(Aliases, &self.aliases);
        self.constant_view = self.constants.view(ConstantView);
        self.provider_signatures = signatures(module.functions);

        self.provider = .{
            .executable = module.function != null,
            .members = &self.member_view,
            .signatures = &self.provider_signatures,
            .aliases = &self.alias_view,
            .kinds = module.types.kinds,
            .constants = &self.constant_view,
            .types = @ptrCast(types),
        };

        self.dependency = .{
            .kind = switch (edge.kind) {
                .type_only => .TypeOnly,
                .function => .Function,
                .enumeration => .Enumeration,
            },
            .names = edge.names,
            .source_names = edge.source_names,
            .wildcard = edge.wildcard,
        };

        self.request = .{
            .provider = &self.provider,
            .consumer = consumer,
            .linked = linked,
            .dependency = &self.dependency,
        };
    }
};

fn signatures(source: ir.SignatureTable) Signatures {
    return .{
        .files = source.files,
        .input_types = source.input_types,
        .output_types = source.output_types,
        .ownership = zx.columns.slice(@FieldType(Signatures, "ownership"), source.ownership),
    };
}
