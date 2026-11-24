const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Export = @import("../../../compiled.zig").Export;
const member_fields = @import("../../../function_import.zig").member_fields;
const header_fields = .{ .names = "name", .paths = "path", .functions = "function" };
const type_fields = .{ .type_names = "name", .type_ids = "type_id" };
const constant_fields = .{ .names = "name", .types = "type_id", .values = "value" };

pub fn View(comptime Target: type) type {
    const Constants = std.meta.Child(@FieldType(Target, "constants"));

    return struct {
        header: memory.ReadFields(header_fields),
        types: memory.ListFields(type_fields),
        members: std.meta.Child(@FieldType(Target, "members")),
        member_lists: memory.ListFields(member_fields),
        constant_lists: memory.ListFields(constant_fields),
        constant_rows: [3]memory.ReadColumn,
        constant_projection: memory.ListProjection,
        constant_columns: std.meta.Child(@FieldType(Constants, "rows")),
        constants: Constants,
        input: Target,
        pub fn init(self: *@This(), exports: []const Export) void {
            self.header = memory.borrowReadFields(header_fields, exports);
            self.types = memory.borrowListFields(&.{"types"}, type_fields, exports);
            self.member_lists = memory.borrowListFields(&.{"members"}, member_fields, exports);
            self.members = self.member_lists.bind(@TypeOf(self.members));
            self.constant_lists = memory.borrowListFields(&.{"constants"}, constant_fields, exports);
            self.constant_projection = .{ .sources = &self.constant_lists.columns, .target = &self.constant_rows };

            self.constant_columns = .{
                .names = @ptrCast(&self.constant_rows[0]),
                .types = @ptrCast(&self.constant_rows[1]),
                .values = @ptrCast(&self.constant_rows[2]),
            };

            self.constants = .{
                .names = @ptrCast(&self.constant_lists.columns[0]),
                .projection = @ptrCast(&self.constant_projection),
                .rows = &self.constant_columns,
            };

            self.header.fill(&self.input);
            self.types.fill(&self.input);

            self.input.members = &self.members;
            self.input.constants = &self.constants;
        }
    };
}
