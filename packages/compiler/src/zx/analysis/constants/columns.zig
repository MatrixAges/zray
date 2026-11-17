const zx = @import("zx");
const ir = zx.ir;

pub const Rows = struct {
    names: zx.memory.TextColumn,
    types: zx.memory.ReadColumn,
    values: zx.memory.ReadColumn,
    pub fn borrow(source: []const ir.Constant) Rows {
        return .{
            .names = zx.memory.borrowTextColumn("name", source),
            .types = zx.memory.borrowReadColumn(ir.TypeId, "type_id", source),
            .values = zx.memory.borrowReadColumn(ir.ConstantValue, "value", source),
        };
    }

    pub fn view(self: *const Rows, comptime Target: type) Target {
        return .{
            .names = @ptrCast(&self.names),
            .types = @ptrCast(&self.types),
            .values = @ptrCast(&self.values),
            .count = self.types.count,
        };
    }
};

pub fn Pair(comptime Input: type) type {
    const std = @import("std");
    const Tables = std.meta.Child(@FieldType(Input, "types"));
    const View = std.meta.Child(@FieldType(Input, "exports"));

    return struct {
        const Self = @This();

        base: std.meta.Child(@FieldType(Tables, "base")),
        delta: std.meta.Child(@FieldType(Tables, "delta")),
        tables: Tables,
        export_rows: Rows,
        import_rows: Rows,
        exports: View,
        imports: View,
        input: Input,
        pub fn init(self: *Self, types: ir.TypeTable, exports: []const ir.Constant, imports: []const ir.Constant) void {
            self.base = ir.TypeTable.borrow(@TypeOf(self.base), types);
            self.delta = ir.TypeTable.borrow(@TypeOf(self.delta), .{});
            self.tables = .{ .base = &self.base, .delta = &self.delta };
            self.export_rows = Rows.borrow(exports);
            self.import_rows = Rows.borrow(imports);
            self.exports = self.export_rows.view(View);
            self.imports = self.import_rows.view(View);
            self.input = .{ .types = &self.tables, .exports = &self.exports, .imports = &self.imports };
        }
    };
}
