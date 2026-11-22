const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("../../nominal_origins.zig");
const Error = @import("../model.zig").Error;
const borrow = @import("../../../ir/canonical/borrow.zig");
const generated = @import("generated_artifact_materialize");
const Nodes = @import("../nodes.zig");
const remap = @import("../nodes/remap.zig");
const Record = @import("../../module_record.zig");
const surfaces = @import("../surface.zig");
const memory = zx.memory;
const Input = std.meta.Child(generated.Input);
const Content = std.meta.Child(@FieldType(Input, "content"));
const Surface = std.meta.Child(@FieldType(Input, "surface"));
const Dependencies = std.meta.Child(@FieldType(Input, "dependencies"));
const Function = @typeInfo(@FieldType(Content, "function")).optional.child;
const Output = std.meta.Child(@typeInfo(@TypeOf(generated.executeValue(undefined, undefined))).error_union.payload);

pub const Result = struct {
    contents: Output,
    surface: surfaces.Surface,
    dependencies: []const Record.Import,
};

pub fn materialize(nodes: *const Nodes, program: *const ir.Program, nominal_types: Origins.Table, prepared: @import("run.zig").Prepared, source: ?*const ir.FunctionView, record: *const Record) Error!Result {
    const table = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "table")), program.types);
    const origins = Origins.Table.borrow(std.meta.Child(@FieldType(Input, "origins")), nominal_types);
    const declarations = ir.SignatureTable.borrow(std.meta.Child(@FieldType(Input, "declarations")), &program.functions);
    const stores = borrow.pointer(@FieldType(Content, "entry_stores"), &program.stores);
    const mapping = remap.typeMapping(std.meta.Child(@FieldType(Content, "type_mapping")), nodes.types);
    var function: remap.FunctionRequest = undefined;

    if (source) |value| function.init(nodes, value, null, .validated);

    const function_input: *const @FieldType(remap.FunctionRequest, "input") = &function.input;

    const content: Content = .{
        .function = if (source != null) borrow.pointer(Function, function_input) else null,
        .entry_stores = stores,
        .type_mapping = &mapping,
        .copy_entry_stores = prepared.body.copy_entry_stores,
    };

    var exported: surfaces.Publication(std.meta.Child(@FieldType(Surface, "exported"))) = undefined;
    var imported: surfaces.Publication(std.meta.Child(@FieldType(Surface, "imported"))) = undefined;
    var imports: surfaces.BindingPublication(std.meta.Child(@FieldType(Surface, "function_imports"))) = undefined;
    var members: surfaces.BindingPublication(std.meta.Child(@FieldType(Surface, "members"))) = undefined;
    var dependencies: DependencyOutput = undefined;

    exported.init(record.exports, record.constant_exports, nodes.types);
    imported.init(record.type_imports, record.constant_imports, nodes.types);
    imports.init(record.function_imports, nodes);
    members.init(record.reexports.functions, nodes);
    dependencies.init(record.imports);

    const input: Input = .{
        .table = &table,
        .origins = &origins,
        .declarations = &declarations,
        .modules = borrow.pointer(@FieldType(Input, "modules"), &program.native_modules),
        .plan = prepared.plan,
        .content = &content,
        .surface = &.{ .exported = &exported.input, .imported = &imported.input, .function_imports = &imports.input, .members = &members.input },
        .path = record.path,
        .dependencies = &dependencies.input,
    };

    const materialized = zx.columns.invoke(generated.executeValue, nodes.allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return .{
        .contents = materialized orelse return error.InvalidModule,
        .surface = .{
            .exports = exported.exports(),
            .constant_exports = exported.constants(),
            .constant_imports = imported.constants(),
            .type_imports = imported.exports(),
            .function_imports = imports.output.rows(),
            .members = members.output.rows(),
        },
        .dependencies = dependencies.output.rows(),
    };
}

const DependencyOutput = struct {
    const Header = @import("../../module_record/columns.zig");
    const Source = std.meta.Child(@FieldType(Dependencies, "source"));
    const Target = std.meta.Child(@FieldType(Dependencies, "target"));

    header: Header,
    header_view: std.meta.Child(@FieldType(Source, "header")),
    names: memory.ReadColumn,
    source_names: memory.ReadColumn,
    path: memory.ReadColumn,
    source: Source,
    input: Dependencies,
    output: memory.RowOutput(Record.Import, Target, .{
        .specifier = &.{"specifier"},
        .identity = &.{"identity"},
        .names = &.{"names"},
        .source_names = &.{"source_names"},
        .path = &.{ "target", "path" },
    }),
    fn init(self: *DependencyOutput, source: []const Record.Import) void {
        self.header = Header.borrow(source);
        self.header_view = self.header.view(@TypeOf(self.header_view));
        self.names = memory.borrowReadColumn([]const []const u8, "names", source);
        self.source_names = memory.borrowReadColumn([]const []const u8, "source_names", source);
        self.path = memory.borrowNestedColumn([]const u8, &.{ "target", "path" }, source);

        self.output.init();

        self.source = .{
            .header = &self.header_view,
            .names = @ptrCast(&self.names),
            .source_names = @ptrCast(&self.source_names),
            .path = @ptrCast(&self.path),
        };

        self.input = .{
            .source = &self.source,
            .target = &self.output.view,
            .storage = @ptrCast(&self.output.buffer),
            .records = std.mem.sliceAsBytes(source),
        };
    }
};
