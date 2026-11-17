const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Module = @import("../../../artifact/model.zig").Module;
const Error = @import("../../../artifact/model.zig").Error;
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const rule = @import("generated_artifact_module_admission");
const Input = std.meta.Child(rule.Input);
const Layout = child("layout");
const Surface = std.meta.Child(@FieldType(Input, "surface"));
const Constants = child("constants");
const Status = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;

fn child(comptime field: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(Input, field)).optional.child);
}

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

pub fn admit(allocator: std.mem.Allocator, module: *const Module, type_count: usize) Error!Mappings {
    const natives = zx.columns.columns(std.meta.Child(@FieldType(Layout, "native_modules")), module.native_modules);
    const signatures = zx.columns.columns(std.meta.Child(@FieldType(Layout, "signatures")), module.functions);
    const Rows = std.meta.Child(@FieldType(Surface, "exports"));
    const export_rows = names.borrow(module.exports);
    const import_rows = names.borrow(module.type_imports);
    var constants: @import("../../../../analysis/constants/columns.zig").Pair(Constants) = undefined;
    const has_constants = module.constant_exports.len != 0 or module.constant_imports.len != 0;

    var request: Input = .{
        .layout = &.{ .native_modules = &natives, .signatures = &signatures },
        .surface = &.{
            .exports = &names.view(Rows, &export_rows),
            .imports = &names.view(Rows, &import_rows),
            .type_count = type_count,
        },
        .constants = null,
    };

    if (try check(allocator, &request) != .Reserve) return error.InvalidModule;

    const mappings = try reserve(allocator, module);

    errdefer {
        allocator.free(mappings.modules);
        allocator.free(mappings.functions);
    }

    if (has_constants) constants.init(module.types, module.constant_exports, module.constant_imports);

    request.layout = null;
    request.constants = if (has_constants) &constants.input else null;

    if (try check(allocator, &request) != .Ready) return error.InvalidModule;

    return mappings;
}

fn check(allocator: std.mem.Allocator, request: *const Input) Error!Status {
    return zx.columns.invoke(rule.executeValue, allocator, request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModule,
    };
}
