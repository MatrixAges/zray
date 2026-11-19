const std = @import("std");
const compiler = @import("compiler");
const model = @import("../../package/manifest/model.zig");
const configuration = compiler.project.native_configuration;
const CompiledNative = @import("compiled_native.zig");
const Inputs = @import("../watch/inputs.zig");
pub const NativeSettings = struct { name: []const u8, root: []const u8, include_paths: []const []const u8 };
pub const Result = struct { scopes: []compiler.project.PackageScope, config: model.Manifest, interfaces: []const compiler.project.NativeInterface, settings: []const NativeSettings };

pub fn load(io: std.Io, allocator: std.mem.Allocator, scopes: []const compiler.project.PackageScope, entry_root: []const u8, entry_config: model.Manifest, inputs: ?*Inputs) !Result {
    var result = Result{ .scopes = try allocator.dupe(compiler.project.PackageScope, scopes), .config = entry_config, .interfaces = &.{}, .settings = &.{} };
    var modules: std.ArrayList(model.NativeModule) = .empty;
    var declarations: std.ArrayList(model.NativeInterface) = .empty;
    var interfaces: std.ArrayList(compiler.project.NativeInterface) = .empty;
    var externals: std.ArrayList(compiler.project.External) = .empty;
    var settings: std.ArrayList(NativeSettings) = .empty;
    var libraries: std.ArrayList([]const u8) = .empty;
    var library_paths: std.ArrayList([]const u8) = .empty;

    for (result.scopes) |*scope| {
        const config = if (std.mem.eql(u8, scope.root, entry_root)) entry_config else try @import("../../package/install/model.zig").read(io, allocator, scope.root, inputs);
        var compiled = try CompiledNative.load(io, allocator, scope.root, config, scopes, inputs);

        defer if (compiled) |*binding| binding.deinit();

        const native = try @import("native.zig").load(io, allocator, scope.root, config, inputs);
        const legacy = try allocator.dupe(compiler.project.External, config.externals);
        var slots: [16][]const u8 = undefined;
        var name_memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&slots), allocator);
        const temporary = name_memory.allocator();

        const names = try configuration.bindNames(allocator, temporary, config.native_modules, .{
            .owner = scope.root,
            .entry_root = entry_root,
            .compiled = compiled != null,
        });

        defer temporary.free(names.resolved);

        for (native, config.native_interfaces) |*entry, original| {
            entry.identity = if (compiled) |binding| try binding.declaration(allocator, entry.specifier) else try configuration.declaration(allocator, scope.root, entry.specifier);
            entry.module = try names.name(allocator, entry.module);

            var declaration = original;
            declaration.module = entry.module;
            declaration.path = entry.path;
            declaration.specifier = entry.key();

            try declarations.append(allocator, declaration);
        }

        for (legacy) |*entry| {
            entry.identity = if (compiled) |binding| try binding.declaration(allocator, entry.specifier) else try configuration.declaration(allocator, scope.root, entry.specifier);
            entry.implementation.module = try names.name(allocator, entry.implementation.module);

            var published = entry.*;

            published.specifier = entry.key();
            published.identity = null;

            try externals.append(allocator, published);
        }

        scope.native_interfaces = native;
        scope.externals = legacy;

        try interfaces.appendSlice(allocator, native);
        try libraries.appendSlice(allocator, config.libraries);
        for (config.library_paths) |path| try library_paths.append(allocator, try std.fs.path.resolve(allocator, &.{ scope.root, path }));

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

            if (configuration.hasModule(modules.items, module.name)) return error.DuplicateNativeModule;
            try modules.append(allocator, module);
            try settings.append(allocator, .{ .name = module.name, .root = scope.root, .include_paths = config.include_paths });
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
