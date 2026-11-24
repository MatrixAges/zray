const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rules = @import("cli_source");
const model = @import("../../../package/manifest/model.zig");
pub const NativeSettings = struct { name: []const u8, root: []const u8, include_paths: []const []const u8 };
const Input = std.meta.Child(rules.native_scope_publication.Input);
const Declarations = std.meta.Child(@FieldType(Input, "declarations"));
const Externals = std.meta.Child(@FieldType(Input, "externals"));
const Settings = std.meta.Child(rules.native_scope_settings.Input);
const declaration_fields = .{ .specifiers = "specifier", .paths = "path", .modules = "module", .namespaces = "namespace" };
const native_fields = .{ .identities = "identity", .specifiers = "specifier", .paths = "path", .modules = "module", .namespaces = "namespace" };
const external_fields = .{ .identities = "identity", .specifiers = "specifier" };
const setting_fields = .{ .names = "name", .roots = "root", .includes = "include_paths" };

pub fn declarations(native: []const compiler.project.NativeInterface, legacy: []const compiler.project.External, exported: []model.NativeInterface, externals: []compiler.project.External) void {
    const native_input = memory.borrowReadFields(native_fields, native);
    const native_output = memory.borrowWriteFields(declaration_fields, exported);
    const external_input = memory.borrowReadFields(.{ .identities = "identity", .names = "specifier" }, legacy);
    const external_output = memory.borrowWriteFields(external_fields, externals);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rules.native_scope_publication.executeValue, scratch.allocator(), &Input{
        .declarations = &.{
            .rows = &native_input.bind(std.meta.Child(@FieldType(Declarations, "rows"))),
            .output = &native_output.bind(std.meta.Child(@FieldType(Declarations, "output"))),
        },
        .externals = &.{
            .rows = &external_input.bind(std.meta.Child(@FieldType(Externals, "rows"))),
            .output = &external_output.bind(std.meta.Child(@FieldType(Externals, "output"))),
        },
    }) catch unreachable;
}

pub fn settings(root: []const u8, includes: []const []const u8, modules: []const model.NativeModule, output: []NativeSettings) void {
    const names = memory.borrowTextColumn("name", modules);
    const target = memory.borrowWriteFields(setting_fields, output);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rules.native_scope_settings.executeValue, scratch.allocator(), &Settings{
        .names = @ptrCast(&names),
        .root = root,
        .includes = includes,
        .count = modules.len,
        .output = &target.bind(std.meta.Child(@FieldType(Settings, "output"))),
    }) catch unreachable;
}
