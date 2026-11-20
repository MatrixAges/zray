const std = @import("std");
const compiler = @import("compiler");
const model = @import("../../package/manifest/model.zig");
const configuration = compiler.project.native_configuration;
const CompiledNative = @import("compiled_native.zig");
const Inputs = @import("watch_inputs").Inputs;
const publish = @import("scopes/publish.zig");
pub const NativeSettings = publish.NativeSettings;
pub const Result = struct { config: model.Manifest, interfaces: []const compiler.project.NativeInterface, settings: []const NativeSettings };

pub fn load(io: std.Io, allocator: std.mem.Allocator, scopes: []compiler.project.PackageScope, manifests: []const model.Manifest, owner: usize, inputs: ?*Inputs) !Result {
    const entry_root = scopes[owner].root;
    var result = Result{ .config = manifests[owner], .interfaces = &.{}, .settings = &.{} };
    var modules: std.ArrayList(model.NativeModule) = .empty;
    var declarations: std.ArrayList(model.NativeInterface) = .empty;
    var interfaces: std.ArrayList(compiler.project.NativeInterface) = .empty;
    var externals: std.ArrayList(compiler.project.External) = .empty;
    var settings: std.ArrayList(NativeSettings) = .empty;
    var libraries: std.ArrayList([]const u8) = .empty;
    var library_paths: std.ArrayList([]const u8) = .empty;
    var registry: compiler.project.source_index.Owned = .{};
    var registry_memory = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer registry_memory.deinit();

    for (scopes, manifests) |*scope, config| {
        var compiled = try CompiledNative.load(io, allocator, scope.root, config, scopes, inputs);

        defer if (compiled) |*binding| binding.deinit();

        const native = try @import("native.zig").load(io, allocator, scope.root, config, inputs);
        const legacy = try allocator.dupe(compiler.project.External, config.externals);
        var slots: [32][]const u8 = undefined;
        var name_memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&slots), allocator);
        const temporary = name_memory.allocator();

        const names = try configuration.bindNames(allocator, temporary, config.native_modules, .{
            .owner = scope.root,
            .entry_root = entry_root,
            .compiled = compiled != null,
        });

        defer names.deinit(temporary);

        for (native) |*entry| {
            entry.identity = if (compiled) |binding| try binding.declaration(allocator, entry.specifier) else try configuration.declaration(allocator, scope.root, entry.specifier);
            entry.module = try names.name(allocator, entry.module);
        }

        for (legacy) |*entry| {
            entry.identity = if (compiled) |binding| try binding.declaration(allocator, entry.specifier) else try configuration.declaration(allocator, scope.root, entry.specifier);
            entry.implementation.module = try names.name(allocator, entry.implementation.module);
        }

        scope.native_interfaces = native;
        scope.externals = legacy;

        if (native.len != 0 or legacy.len != 0) {
            const exported = try declarations.addManyAsSlice(allocator, native.len);
            const external_first = externals.items.len;

            try externals.appendSlice(allocator, legacy);

            publish.declarations(native, legacy, exported, externals.items[external_first..]);
        }

        try interfaces.appendSlice(allocator, native);
        try libraries.appendSlice(allocator, config.libraries);

        const resolved_libraries = try library_paths.addManyAsSlice(allocator, config.library_paths.len);

        for (config.library_paths, resolved_libraries) |path, *resolved| {
            resolved.* = try std.fs.path.resolve(allocator, &.{ scope.root, path });
        }

        const first = modules.items.len;

        try modules.ensureUnusedCapacity(allocator, config.native_modules.len);

        for (config.native_modules, names.resolved) |original, name| {
            var module = original;

            module.name = name;

            if (original.path) |path| module.path = try std.fs.path.resolve(allocator, &.{ scope.root, path });

            module.dependencies = try names.dependencies(allocator, original.dependencies);
            const includes = original.include_paths orelse config.include_paths;
            const resolved_includes = try allocator.alloc([]const u8, includes.len);

            for (includes, resolved_includes) |path, *resolved| resolved.* = try std.fs.path.resolve(allocator, &.{ scope.root, path });

            module.include_paths = resolved_includes;

            module.abi_aliases = if (compiled) |binding|
                try binding.aliases(allocator, original.abi_aliases)

            else
                try compiler.project.compiled.identity.sourceAliases(allocator, native, legacy, model.AbiAlias, original.abi_aliases);

            if (try registry.register(registry_memory.allocator(), module.name, modules.items.len) != null) return error.DuplicateNativeModule;

            modules.appendAssumeCapacity(module);
        }

        const scoped_modules = modules.items[first..];

        if (scoped_modules.len != 0) {
            const output = try settings.addManyAsSlice(allocator, scoped_modules.len);

            publish.settings(scope.root, config.include_paths, scoped_modules, output);
        }
    }

    result.config.native_modules = try modules.toOwnedSlice(allocator);
    result.config.native_interfaces = try declarations.toOwnedSlice(allocator);
    result.config.externals = try externals.toOwnedSlice(allocator);
    result.config.libraries = try libraries.toOwnedSlice(allocator);
    result.config.library_paths = try library_paths.toOwnedSlice(allocator);
    result.interfaces = try interfaces.toOwnedSlice(allocator);
    result.settings = try settings.toOwnedSlice(allocator);

    return result;
}
