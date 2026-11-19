const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rules = @import("cli_source");
const model = @import("../../../package/manifest/model.zig");
pub const NativeSettings = struct { name: []const u8, root: []const u8, include_paths: []const []const u8 };
const Input = std.meta.Child(rules.native_scope_publication.Input);
const Settings = std.meta.Child(rules.native_scope_settings.Input);

pub fn declarations(native: []const compiler.project.NativeInterface, legacy: []const compiler.project.External, exported: []model.NativeInterface, externals: []compiler.project.External) void {
    const identities = memory.borrowReadColumn(?[]const u8, "identity", native);
    const specifiers = memory.borrowTextColumn("specifier", native);
    const paths = memory.borrowTextColumn("path", native);
    const modules = memory.borrowTextColumn("module", native);
    const namespaces = memory.borrowReadColumn([]const []const u8, "namespace", native);
    const external_identities = memory.borrowReadColumn(?[]const u8, "identity", legacy);
    const external_specifiers = memory.borrowTextColumn("specifier", legacy);
    const output_specifiers = memory.borrowWriteColumn([]const u8, "specifier", exported);
    const output_paths = memory.borrowWriteColumn([]const u8, "path", exported);
    const output_modules = memory.borrowWriteColumn([]const u8, "module", exported);
    const output_namespaces = memory.borrowWriteColumn([]const []const u8, "namespace", exported);
    const output_external_specifiers = memory.borrowWriteColumn([]const u8, "specifier", externals);
    const output_external_identities = memory.borrowWriteColumn(?[]const u8, "identity", externals);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rules.native_scope_publication.executeValue, scratch.allocator(), &Input{
        .declarations = &.{
            .rows = &.{
                .identities = @ptrCast(&identities),
                .specifiers = @ptrCast(&specifiers),
                .paths = @ptrCast(&paths),
                .modules = @ptrCast(&modules),
                .namespaces = @ptrCast(&namespaces),
                .count = native.len,
            },
            .specifiers = @ptrCast(&output_specifiers),
            .paths = @ptrCast(&output_paths),
            .modules = @ptrCast(&output_modules),
            .namespaces = @ptrCast(&output_namespaces),
        },
        .externals = &.{
            .identities = @ptrCast(&external_identities),
            .names = @ptrCast(&external_specifiers),
            .specifiers = @ptrCast(&output_external_specifiers),
            .output_identities = @ptrCast(&output_external_identities),
            .count = legacy.len,
        },
    }) catch unreachable;
}

pub fn settings(root: []const u8, includes: []const []const u8, modules: []const model.NativeModule, output: []NativeSettings) void {
    const names = memory.borrowTextColumn("name", modules);
    const output_names = memory.borrowWriteColumn([]const u8, "name", output);
    const output_roots = memory.borrowWriteColumn([]const u8, "root", output);
    const output_includes = memory.borrowWriteColumn([]const []const u8, "include_paths", output);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rules.native_scope_settings.executeValue, scratch.allocator(), &Settings{
        .names = @ptrCast(&names),
        .root = root,
        .includes = includes,
        .count = modules.len,
        .output_names = @ptrCast(&output_names),
        .output_roots = @ptrCast(&output_roots),
        .output_includes = @ptrCast(&output_includes),
    }) catch unreachable;
}
