const std = @import("std");
const zx = @import("zx");
const Artifact = @import("../../../artifact/model.zig");
const Current = @import("../../restore.zig").Current;
const Record = @import("../../../module_record.zig");
const RecordColumns = @import("../../../module_record/columns.zig");
const Transaction = std.meta.Child(@FieldType(std.meta.Child(@import("generated_semantic_restore").Input), "planning"));
const Input = std.meta.Child(@FieldType(Transaction, "preflight"));
const Modules = std.meta.Child(@FieldType(Input, "cached_modules"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Dependencies = std.meta.Child(@FieldType(Input, "dependencies"));
const Columns = std.meta.Child(@FieldType(Dependencies, "previous"));
const Header = std.meta.Child(@FieldType(Columns, "header"));
const Control = std.meta.Child(@typeInfo(@FieldType(Input, "control")).optional.child);
const Workspace = std.meta.Child(@FieldType(Control, "workspace"));

depths: zx.memory.U32Scratch,
workspace: Workspace,
control: Control,
previous: Rows,
incoming: Rows,
previous_header: Header,
incoming_header: Header,
previous_rows: Columns,
incoming_rows: Columns,
dependencies: Dependencies,
input: Input,
const Self = @This();

pub fn init(self: *Self, temporary: std.mem.Allocator, module: *const Artifact.Module, current: *const Current, decoded: bool, previous_modules: anytype, current_modules: anytype, previous_signatures: anytype) void {
    const unchecked = if (decoded) null else if (module.function) |*value| value else null;

    self.depths = .{ .allocator = temporary };

    if (unchecked) |value| {
        self.workspace = self.depths.borrow(Workspace, true);

        self.control = .{
            .control = zx.columns.pointer(@FieldType(Control, "control"), value.body.control),
            .root = if (value.body.root) |root| @backingInt(root) else null,
            .workspace = &self.workspace,
        };
    }

    self.previous = .borrow(module.dependencies);
    self.incoming = .borrow(current.dependencies);
    self.previous_header = self.previous.header.view(Header);
    self.incoming_header = self.incoming.header.view(Header);
    self.previous_rows = self.previous.view(&self.previous_header);
    self.incoming_rows = self.incoming.view(&self.incoming_header);
    self.dependencies = .{ .previous = &self.previous_rows, .current = &self.incoming_rows };

    self.input = .{
        .signatures = zx.columns.pointer(*const Signatures, previous_signatures),
        .cached_modules = zx.columns.pointer(*const Modules, previous_modules),
        .current_modules = zx.columns.pointer(*const Modules, current_modules),
        .types = module.type_imports.len,
        .current_types = current.aliases.len,
        .functions = module.function_imports.len,
        .current_functions = current.imports.len,
        .constants = module.constant_imports.len,
        .current_constants = current.constant_imports.len,
        .members = module.members.len,
        .current_members = current.members.len,
        .decoded = decoded,
        .verified_native = current.verified.native,
        .dependencies = &self.dependencies,
        .control = if (unchecked != null) &self.control else null,
    };
}

const Rows = struct {
    header: RecordColumns,
    names: zx.memory.ReadColumn,
    source_names: zx.memory.ReadColumn,
    kind: zx.memory.ReadColumn,
    exported: zx.memory.ReadColumn,
    wildcard: zx.memory.ReadColumn,
    path: zx.memory.TextColumn,
    instance: zx.memory.TextColumn,
    member: zx.memory.TextColumn,
    fn borrow(items: []const Record.Import) Rows {
        const memory = zx.memory;

        return .{
            .header = .borrow(items),
            .names = memory.borrowReadColumn([]const []const u8, "names", items),
            .source_names = memory.borrowReadColumn([]const []const u8, "source_names", items),
            .kind = memory.borrowReadColumn(@FieldType(Record.Import, "kind"), "kind", items),
            .exported = memory.borrowReadColumn(bool, "exported", items),
            .wildcard = memory.borrowReadColumn(bool, "wildcard", items),
            .path = memory.borrowNestedColumn([]const u8, &.{ "target", "path" }, items),
            .instance = memory.borrowNestedColumn([]const u8, &.{ "target", "instance" }, items),
            .member = memory.borrowNestedColumn([]const u8, &.{ "target", "member" }, items),
        };
    }
    fn view(self: *const Rows, header: *const Header) Columns {
        return .{
            .header = header,
            .names = @ptrCast(&self.names),
            .source_names = @ptrCast(&self.source_names),
            .kind = @ptrCast(&self.kind),
            .exported = @ptrCast(&self.exported),
            .wildcard = @ptrCast(&self.wildcard),
            .path = @ptrCast(&self.path),
            .instance = @ptrCast(&self.instance),
            .member = @ptrCast(&self.member),
        };
    }
};
