const std = @import("std");
const zx = @import("zx");
const Artifact = @import("../../../artifact/model.zig");
const Current = @import("../../restore.zig").Current;
const Record = @import("../../../module_record.zig");
const RecordColumns = @import("../../../module_record/columns.zig");
const generated = @import("generated_semantic_restore_preflight");
const Input = std.meta.Child(generated.Input);
const Modules = std.meta.Child(@FieldType(Input, "cached_modules"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Dependencies = std.meta.Child(@FieldType(Input, "dependencies"));
const Columns = std.meta.Child(@FieldType(Dependencies, "previous"));
const Header = std.meta.Child(@FieldType(Columns, "header"));
const Control = std.meta.Child(@typeInfo(@FieldType(Input, "control")).optional.child);

pub fn check(temporary: std.mem.Allocator, module: *const Artifact.Module, current: *const Current, decoded: bool) std.mem.Allocator.Error!bool {
    const previous_modules = zx.columns.columns(Modules, module.native_modules);
    const current_modules = zx.columns.columns(Modules, current.native_modules);
    const previous_signatures = zx.columns.columns(Signatures, module.functions);
    var control: Control = undefined;
    const unchecked = if (decoded) null else if (module.function) |*body| body else null;

    if (unchecked) |body| {
        control = .{
            .control = zx.columns.pointer(@FieldType(Control, "control"), body.body.control),
            .root = if (body.body.root) |root| @backingInt(root) else null,
        };
    }

    const previous = Rows.borrow(module.dependencies);
    const incoming = Rows.borrow(current.dependencies);
    const previous_header = previous.header.view(Header);
    const incoming_header = incoming.header.view(Header);
    const previous_rows = previous.view(&previous_header);
    const incoming_rows = incoming.view(&incoming_header);

    const input: Input = .{
        .signatures = &previous_signatures,
        .cached_modules = &previous_modules,
        .current_modules = &current_modules,
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
        .dependencies = &.{ .previous = &previous_rows, .current = &incoming_rows },
        .control = if (unchecked != null) &control else null,
    };

    return zx.columns.invoke(generated.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => false,
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
