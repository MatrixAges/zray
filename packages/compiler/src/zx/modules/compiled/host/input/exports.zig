const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Export = @import("../../../compiled.zig").Export;

pub fn View(comptime Target: type) type {
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
        input: Target,
        pub fn init(self: *@This(), allocator: std.mem.Allocator, exports: []const Export) std.mem.Allocator.Error!void {
            const Optional = std.meta.Child(@FieldType(Target, "constants"));
            const Item = @typeInfo(Optional).optional.child;
            const Values = if (@typeInfo(Item) == .pointer) std.meta.Child(Item) else Item;
            const constants = try allocator.alloc(Optional, exports.len);

            for (exports, constants) |exported, *constant| {
                const values = try @import("../../../../analysis/constants/input.zig").marshal(Values, allocator, exported.constants);

                constant.* = if (values) |value| if (@typeInfo(Item) == .pointer) value else value.* else null;
            }

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

            self.input = .{
                .count = exports.len,
                .names = @ptrCast(&self.names),
                .paths = @ptrCast(&self.paths),
                .functions = @ptrCast(&self.functions),
                .type_names = @ptrCast(&self.type_names),
                .type_ids = @ptrCast(&self.type_ids),
                .members = &self.members,
                .constants = constants,
            };
        }
    };
}
