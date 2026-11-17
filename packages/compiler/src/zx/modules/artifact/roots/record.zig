const std = @import("std");
const ir = @import("zx").ir;
const names = @import("../../../ir/canonical/validation/names/view.zig");
const Record = @import("../../module_record.zig");
const RecordColumns = @import("../../module_record/columns.zig");
const Binding = @import("../../function_import.zig");

pub fn View(comptime Target: type) type {
    const Aliases = std.meta.Child(@FieldType(Target, "exports"));
    const ColumnsView = std.meta.Child(@FieldType(Target, "constant_exports"));
    const Dependencies = std.meta.Child(@FieldType(Target, "dependencies"));
    const Ports = std.meta.Child(@FieldType(Target, "function_imports"));

    return struct {
        export_rows: names.Rows,
        import_rows: names.Rows,
        exports: Aliases,
        imports: Aliases,
        dependency_columns: RecordColumns,
        dependencies: Dependencies,
        constants: ColumnsView,
        constant_imports: ColumnsView,
        import_ports: Binding.Readable,
        export_ports: Binding.Readable,
        function_imports: Ports,
        function_exports: Ports,
        plan: Target,
        pub fn init(self: *@This(), record: Record) void {
            self.import_ports = .borrowRows(record.function_imports);
            self.export_ports = .borrowRows(record.reexports.functions);
            self.function_imports = self.import_ports.view(Ports);
            self.function_exports = self.export_ports.view(Ports);
            self.dependency_columns = .borrow(record.imports);
            self.dependencies = self.dependency_columns.view(Dependencies);
            self.export_rows = names.borrow(record.exports);
            self.import_rows = names.borrow(record.type_imports);
            self.exports = names.view(Aliases, &self.export_rows);
            self.imports = names.view(Aliases, &self.import_rows);
            self.constants = constants(record.constant_exports, ColumnsView);
            self.constant_imports = constants(record.constant_imports, ColumnsView);

            self.plan = .{
                .path = record.path,
                .start = record.type_range.start,
                .end = record.type_range.end,
                .exports = &self.exports,
                .constant_exports = &self.constants,
                .constant_imports = &self.constant_imports,
                .type_imports = &self.imports,
                .function_imports = &self.function_imports,
                .function_exports = &self.function_exports,
                .dependencies = &self.dependencies,
                .has_body = record.body != .types,
                .body_function = if (record.own_function) |id| @backingInt(id) else if (record.body == .function) @backingInt(record.body.function) else null,
            };
        }
    };
}

fn constants(source: []const ir.Constant, comptime Target: type) Target {
    comptime std.debug.assert(@typeInfo(ir.TypeId).@"enum".tag_type == u32);

    return .{
        .data = std.mem.sliceAsBytes(source),
        .rows = source.len,
        .stride = @sizeOf(ir.Constant),
        .field = @offsetOf(ir.Constant, "type_id"),
        .little_endian = @import("builtin").target.cpu.arch.endian() == .little,
    };
}
