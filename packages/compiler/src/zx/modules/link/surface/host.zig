const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Error = @import("../../artifact/model.zig").Error;
const names = @import("../../../ir/canonical/validation/names/view.zig");

pub fn admit(allocator: std.mem.Allocator, exports: []const ir.Export, imports: []const ir.Export, count: usize) Error!void {
    if (exports.len == 0 and imports.len == 0) return;

    const generated = @import("generated_artifact_type_admission");
    const Input = std.meta.Child(generated.Input);
    const Rows = std.meta.Child(@FieldType(Input, "exports"));
    const export_rows = names.borrow(exports);
    const import_rows = names.borrow(imports);
    const exported = names.view(Rows, &export_rows);
    const imported = names.view(Rows, &import_rows);

    const input: Input = .{
        .exports = &exported,
        .imports = &imported,
        .type_count = count,
    };

    const valid = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (!valid) return error.InvalidModule;
}
