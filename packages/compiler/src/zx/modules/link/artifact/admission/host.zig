const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Module = @import("../../../artifact/model.zig").Module;
const Error = @import("../../../artifact/model.zig").Error;
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const Binding = @import("../binding/abi.zig").Binding;
const Input = std.meta.Child(@FieldType(Binding, "admission"));
const Layout = std.meta.Child(@FieldType(Input, "layout"));
const Surface = std.meta.Child(@FieldType(Input, "surface"));
const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "constants")).optional.child);

pub const Mappings = struct {
    functions: []?ir.FunctionId,
    modules: []?ir.NativeModuleId,
};

pub fn reserve(allocator: std.mem.Allocator, module: *const Module) Error!Mappings {
    const functions = try allocator.alloc(?ir.FunctionId, module.functions.count() + @intFromBool(module.function != null));

    errdefer allocator.free(functions);

    const modules = try allocator.alloc(?ir.NativeModuleId, module.native_modules.count());

    @memset(functions, null);

    return .{ .functions = functions, .modules = modules };
}

const Natives = std.meta.Child(@FieldType(Layout, "native_modules"));
const Signatures = std.meta.Child(@FieldType(Layout, "signatures"));
const Rows = std.meta.Child(@FieldType(Surface, "exports"));
const Names = @TypeOf(names.borrow(@as([]const ir.Export, &.{})));

pub const View = struct {
    input: Input,
    natives: Natives,
    signatures: Signatures,
    layout: Layout,
    surface: Surface,
    export_rows: Names,
    import_rows: Names,
    exports: Rows,
    imports: Rows,
    constants: @import("../../../../analysis/constants/columns.zig").Pair(Constants),
    pub fn init(self: *View, module: *const Module, type_count: usize) void {
        self.natives = zx.columns.columns(Natives, module.native_modules);
        self.signatures = zx.columns.columns(Signatures, module.functions);
        self.layout = .{ .native_modules = &self.natives, .signatures = &self.signatures };
        self.export_rows = names.borrow(module.exports);
        self.import_rows = names.borrow(module.type_imports);
        self.exports = names.view(Rows, &self.export_rows);
        self.imports = names.view(Rows, &self.import_rows);
        self.surface = .{ .exports = &self.exports, .imports = &self.imports, .type_count = type_count };

        const has_constants = module.constant_exports.len != 0 or module.constant_imports.len != 0;

        if (has_constants) self.constants.init(module.types, module.constant_exports, module.constant_imports);

        self.input = .{
            .layout = &self.layout,
            .surface = &self.surface,
            .constants = if (has_constants) &self.constants.input else null,
        };
    }
};
