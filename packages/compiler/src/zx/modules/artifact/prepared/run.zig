const std = @import("std");
const ir = @import("zx").ir;
const Analysis = @import("../../../analysis/analyze.zig");
const Record = @import("../../module_record.zig");
const Origins = @import("../../nominal_origins.zig");
const Error = @import("../model.zig").Error;
const borrow = @import("../../../ir/canonical/borrow.zig");
const generated = @import("generated_artifact_extract");
const projection = @import("../roots/record.zig");
const source_view = @import("../roots/run.zig");
const Input = std.meta.Child(@FieldType(std.meta.Child(generated.Input), "preparation"));
const Source = std.meta.Child(@FieldType(Input, "source"));
const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "constants")).optional.child);
const Projected = std.meta.Child(@FieldType(Source, "record"));
const Self = @This();

view: projection.View(Projected),
table: std.meta.Child(@FieldType(Source, "table")),
origins: std.meta.Child(@FieldType(Input, "origins")),
functions: std.meta.Child(@FieldType(Source, "functions")),
entry: std.meta.Child(@FieldType(Source, "entry")),
source: Source,
body: std.meta.Child(@FieldType(Input, "body")),
constants: @import("../../../analysis/constants/columns.zig").Pair(Constants),
input: Input,
pub fn bind(self: *Self, temporary: std.mem.Allocator, analysis: *const Analysis.Result, record: *const Record) Error!void {
    _ = temporary;

    const program = &analysis.value.ir;

    self.view.init(record.*);

    self.table = ir.TypeTable.borrow(std.meta.Child(@FieldType(Source, "table")), program.types);
    self.origins = Origins.Table.borrow(std.meta.Child(@FieldType(Input, "origins")), analysis.nominal_types);
    self.functions = source_view.functions(std.meta.Child(@FieldType(Source, "functions")), program);
    self.entry = source_view.body(std.meta.Child(@FieldType(Source, "entry")), program);

    self.source = .{
        .file_name = program.file_name,
        .type_only = program.type_only,
        .table = &self.table,
        .functions = &self.functions,
        .modules = borrow.pointer(@FieldType(Source, "modules"), &program.native_modules),
        .entry = &self.entry,
        .record = &self.view.plan,
    };

    self.body = .{
        .kind = switch (record.body) {
            .types => .Types,
            .entry => .Entry,
            .function => .Function,
        },
        .function_id = if (record.body == .function) @backingInt(record.body.function) else null,
        .own_function = if (record.own_function) |id| @backingInt(id) else null,
    };

    const has_constants = record.constant_exports.len != 0 or record.constant_imports.len != 0;

    if (has_constants) self.constants.init(program.types, record.constant_exports, record.constant_imports);

    self.input = .{
        .source = &self.source,
        .body = &self.body,
        .origins = &self.origins,
        .origin_names = analysis.nominal_types.names,
        .constants = if (has_constants) &self.constants.input else null,
        .scalar_count = std.enums.values(ir.Scalar).len,
        .maximum_count = std.math.maxInt(u32),
    };
}
