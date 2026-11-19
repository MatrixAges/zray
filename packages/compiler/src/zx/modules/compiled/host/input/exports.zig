const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Export = @import("../../../compiled.zig").Export;

pub fn View(comptime Target: type) type {
    const Constants = std.meta.Child(@FieldType(Target, "constants"));

    return struct {
        names: memory.TextColumn,
        paths: memory.TextColumn,
        functions: memory.ReadColumn,
        type_names: memory.ListColumn,
        type_ids: memory.ListColumn,
        members: std.meta.Child(@FieldType(Target, "members")),
        member_names: memory.ListColumn,
        member_namespaces: memory.ListColumn,
        member_ids: memory.ListColumn,
        member_inputs: memory.ListColumn,
        member_outputs: memory.ListColumn,
        member_intrinsics: memory.ListColumn,
        constant_lists: [3]memory.ListColumn,
        constant_rows: [3]memory.ReadColumn,
        constant_projection: memory.ListProjection,
        constant_columns: std.meta.Child(@FieldType(Constants, "rows")),
        constants: Constants,
        input: Target,
        pub fn init(self: *@This(), exports: []const Export) void {
            self.names = memory.borrowTextColumn("name", exports);
            self.paths = memory.borrowTextColumn("path", exports);
            self.functions = memory.borrowOptionalU32Column("function", exports);
            self.type_names = memory.borrowListColumn([]const u8, "types", "name", exports);
            self.type_ids = memory.borrowListColumn(zx.ir.TypeId, "types", "type_id", exports);

            const Binding = std.meta.Child(@FieldType(Export, "members"));

            self.member_names = memory.borrowListColumn([]const u8, "members", "name", exports);
            self.member_namespaces = memory.borrowListColumn(?[]const u8, "members", "namespace", exports);
            self.member_ids = memory.borrowListColumn(@FieldType(Binding, "id"), "members", "id", exports);
            self.member_inputs = memory.borrowListColumn(@FieldType(Binding, "input_type"), "members", "input_type", exports);
            self.member_outputs = memory.borrowListColumn(@FieldType(Binding, "output_type"), "members", "output_type", exports);
            self.member_intrinsics = memory.borrowListColumn(@FieldType(Binding, "intrinsic"), "members", "intrinsic", exports);

            self.members = .{
                .names = @ptrCast(&self.member_names),
                .namespaces = @ptrCast(&self.member_namespaces),
                .ids = @ptrCast(&self.member_ids),
                .inputs = @ptrCast(&self.member_inputs),
                .outputs = @ptrCast(&self.member_outputs),
                .intrinsics = @ptrCast(&self.member_intrinsics),
            };

            self.constant_lists = .{
                memory.borrowListColumn([]const u8, "constants", "name", exports),
                memory.borrowListColumn(zx.ir.TypeId, "constants", "type_id", exports),
                memory.borrowListColumn(zx.ir.ConstantValue, "constants", "value", exports),
            };

            self.constant_projection = .{ .sources = &self.constant_lists, .target = &self.constant_rows };

            self.constant_columns = .{
                .names = @ptrCast(&self.constant_rows[0]),
                .types = @ptrCast(&self.constant_rows[1]),
                .values = @ptrCast(&self.constant_rows[2]),
            };

            self.constants = .{
                .names = @ptrCast(&self.constant_lists[0]),
                .projection = @ptrCast(&self.constant_projection),
                .rows = &self.constant_columns,
            };

            self.input = .{
                .count = exports.len,
                .names = @ptrCast(&self.names),
                .paths = @ptrCast(&self.paths),
                .functions = @ptrCast(&self.functions),
                .type_names = @ptrCast(&self.type_names),
                .type_ids = @ptrCast(&self.type_ids),
                .members = &self.members,
                .constants = &self.constants,
            };
        }
    };
}
