const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const borrow = @import("../../../ir/canonical/borrow.zig");
const generated = @import("generated_artifact_extract");
const Nodes = @import("../nodes.zig");
const remap = @import("../nodes/remap.zig");
const Record = @import("../../module_record.zig");
const Binding = @import("../../function_import.zig");
const surfaces = @import("../surface.zig");
const memory = zx.memory;
const Input = std.meta.Child(@typeInfo(@FieldType(std.meta.Child(generated.Input), "materialization")).optional.child);
const Content = std.meta.Child(@FieldType(Input, "content"));
const Surface = std.meta.Child(@FieldType(Input, "surface"));
const Dependencies = std.meta.Child(@FieldType(Input, "dependencies"));
const Self = @This();

declarations: std.meta.Child(@FieldType(Input, "declarations")),
mapping: std.meta.Child(@FieldType(Content, "type_mapping")),
function: remap.FunctionRequest,
content: Content,
exported: surfaces.Publication(std.meta.Child(@FieldType(Surface, "exported"))),
imported: surfaces.Publication(std.meta.Child(@FieldType(Surface, "imported"))),
imports: surfaces.BindingPublication(std.meta.Child(@FieldType(Surface, "function_imports"))),
members: surfaces.BindingPublication(std.meta.Child(@FieldType(Surface, "members"))),
dependencies: DependencyInput,
surface: Surface,
input: Input,
pub fn bind(self: *Self, nodes: *const Nodes, program: *const ir.Program, source: ?*const ir.FunctionView, copy_entry_stores: bool, record: *const Record) void {
    self.declarations = ir.SignatureTable.borrow(@TypeOf(self.declarations), &program.functions);
    self.mapping = remap.typeMapping(@TypeOf(self.mapping), nodes.types);

    if (source) |value| self.function.init(nodes, value, null, .validated);

    self.content = .{
        .function = if (source != null) &self.function.input else null,
        .entry_stores = borrow.pointer(@FieldType(Content, "entry_stores"), &program.stores),
        .type_mapping = &self.mapping,
        .copy_entry_stores = copy_entry_stores,
    };

    self.exported.init(record.exports, record.constant_exports, nodes.types);
    self.imported.init(record.type_imports, record.constant_imports, nodes.types);
    self.imports.init(record.function_imports, nodes);
    self.members.init(record.reexports.functions, nodes);
    self.dependencies.init(record.imports);

    self.surface = .{ .exported = &self.exported.input, .imported = &self.imported.input, .function_imports = &self.imports.input, .members = &self.members.input };

    self.input = .{
        .declarations = &self.declarations,
        .content = &self.content,
        .surface = &self.surface,
        .path = record.path,
        .dependencies = &self.dependencies.input,
    };
}

pub fn publishedSurface(self: *const Self, imports: []const Binding, members: []const Binding) surfaces.Surface {
    return .{
        .exports = self.exported.exports(),
        .constant_exports = self.exported.constants(),
        .constant_imports = self.imported.constants(),
        .type_imports = self.imported.exports(),
        .function_imports = imports,
        .members = members,
    };
}

const DependencyInput = struct {
    const Header = @import("../../module_record/columns.zig");

    header: Header,
    header_view: std.meta.Child(@FieldType(Dependencies, "header")),
    names: memory.ReadColumn,
    source_names: memory.ReadColumn,
    path: memory.ReadColumn,
    input: Dependencies,
    fn init(self: *DependencyInput, source: []const Record.Import) void {
        self.header = Header.borrow(source);
        self.header_view = self.header.view(@TypeOf(self.header_view));
        self.names = memory.borrowReadColumn([]const []const u8, "names", source);
        self.source_names = memory.borrowReadColumn([]const []const u8, "source_names", source);
        self.path = memory.borrowNestedColumn([]const u8, &.{ "target", "path" }, source);

        self.input = .{
            .header = &self.header_view,
            .names = @ptrCast(&self.names),
            .source_names = @ptrCast(&self.source_names),
            .path = @ptrCast(&self.path),
        };
    }
};
