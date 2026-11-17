const memory = @import("zx").memory;
const Binding = @import("../../../function_import.zig");

pub const Columns = struct {
    names: memory.TextColumn,
    namespaces: memory.TextColumn,
    ids: memory.ReadColumn,
    inputs: memory.ReadColumn,
    outputs: memory.ReadColumn,
    intrinsics: memory.ReadColumn,
    pub fn borrow(source: []const Binding) Columns {
        return .{
            .names = memory.borrowTextColumn("name", source),
            .namespaces = memory.borrowReadColumn(?[]const u8, "namespace", source),
            .ids = memory.borrowOptionalU32Column("id", source),
            .inputs = memory.borrowOptionalU32Column("input_type", source),
            .outputs = memory.borrowOptionalU32Column("output_type", source),
            .intrinsics = memory.borrowOptionalU8Column("intrinsic", source),
        };
    }

    pub fn view(self: *const Columns, comptime Target: type) Target {
        return .{
            .names = @ptrCast(&self.names),
            .namespaces = @ptrCast(&self.namespaces),
            .ids = @ptrCast(&self.ids),
            .inputs = @ptrCast(&self.inputs),
            .outputs = @ptrCast(&self.outputs),
            .intrinsics = @ptrCast(&self.intrinsics),
            .count = self.names.count,
        };
    }
};
