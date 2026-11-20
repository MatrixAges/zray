const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const ir = zx.ir;
const Current = @import("../../restore.zig").Current;
const validation = @import("generated_ir_validation");
const Validation = std.meta.Child(validation.Input);
const Context = std.meta.Child(@FieldType(Validation, "context"));
const Table = std.meta.Child(@FieldType(Context, "table"));
const Complete = std.meta.Child(@FieldType(Context, "functions"));

pub fn View(comptime Input: type) type {
    const Views = std.meta.Child(@FieldType(Input, "views"));
    const Base = std.meta.Child(@FieldType(Views, "context"));
    const Workspace = std.meta.Child(@FieldType(Base, "workspace"));
    const Prefix = std.meta.Child(@typeInfo(@FieldType(Base, "verified_types")).optional.child);
    const Exports = std.meta.Child(@FieldType(Input, "exports"));
    const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "constant_exports")).optional.child);

    return struct {
        table: Table,
        functions: Complete,
        type_slots: [@typeInfo(Table).@"struct".field_names.len]*anyopaque,
        function_slots: [@typeInfo(Complete).@"struct".field_names.len]*anyopaque,
        type_storage: memory.ColumnSet,
        function_storage: memory.ColumnSet,
        prefix: Prefix,
        depths: memory.U32Scratch,
        workspace: Workspace,
        base: Base,
        exports: Exports,
        reads: [3]memory.ReadColumn,
        growth: memory.RowGrowth,
        constants: Constants,
        views: Views,
        input: Input,
        pub fn init(self: *@This(), target: *const Current, surface: anytype, scope: *memory.ArenaScope, scratch: *const std.mem.Allocator, payload: *const std.mem.Allocator) void {
            self.type_slots = memory.bindColumnSet(Table, false, target.types);
            self.function_slots = memory.bindColumnSet(Complete, false, target.functions);
            self.type_storage = &self.type_slots;
            self.function_storage = &self.function_slots;
            self.depths = .{ .allocator = scratch.* };
            self.workspace = self.depths.borrow(Workspace, false);

            const verified = target.verified.*;

            if (verified.types) |prefix| self.prefix = zx.columns.view(Prefix, prefix);

            self.base = .{
                .modules = zx.columns.pointer(@FieldType(Base, "modules"), &target.native_modules),
                .max_offset = std.math.maxInt(usize),
                .scalar_count = std.enums.values(ir.Scalar).len,
                .maximum_count = std.math.maxInt(u32),
                .verified = verified.functions,
                .verified_types = if (verified.types != null) &self.prefix else null,
                .verified_native = verified.native,
                .workspace = &self.workspace,
            };

            self.exports = .{ .rows = @ptrCast(&surface.export_target), .length = surface.export_source.length };
            self.growth = .{ .target = &surface.constant_output.buffer, .reads = &self.reads };

            self.constants = .{
                .names = @ptrCast(&self.reads[0]),
                .types = @ptrCast(&self.reads[1]),
                .values = @ptrCast(&self.reads[2]),
                .count = surface.constant_source.count,
            };

            self.views = .{
                .context = &self.base,
                .type_storage = @ptrCast(&self.type_storage),
                .type_view = @ptrCast(&self.table),
                .function_storage = @ptrCast(&self.function_storage),
                .function_view = @ptrCast(&self.functions),
                .constants = if (self.constants.count != 0) @ptrCast(&self.growth) else null,
            };

            self.input = .{
                .version = zx.ir_version,
                .exports = &self.exports,
                .constant_exports = if (self.constants.count != 0) &self.constants else null,
                .views = &self.views,
                .scope = @ptrCast(scope),
                .scratch = @ptrCast(scratch),
                .payload = @ptrCast(payload),
            };
        }
    };
}
