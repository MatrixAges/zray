const std = @import("std");
const compiler = @import("compiler");
const CompiledNative = @import("../compiled_native.zig");
const State = @import("state.zig");
const effects = @import("../../sources/effects.zig");
const storage = @import("publish.zig");
const configuration = compiler.project.native_configuration;
const abi = @import("cli_abi").layouts.@"zig:native_scope_host";

pub fn openNativeScope(handle: *const anyopaque, index: u64) effects.Error!*const abi.ScopeWindow {
    const self = State.get(handle);

    self.current = @intCast(index);

    const config = self.config();
    const root = self.scope().root;

    self.compiled = CompiledNative.load(self.io, self.allocator, root, config.*, self.scopes, self.inputs) catch |err| return self.failure.save(err);

    configuration.validateExternals(config.externals) catch |err| return self.failure.save(err);

    self.native = self.allocator.alloc(compiler.project.NativeInterface, config.native_interfaces.len) catch |err| return self.failure.save(err);

    self.window = .{
        .frame = @ptrCast(handle),
        .declarations = self.native.len,
        .externals = config.externals.len,
        .modules = config.native_modules.len,
        .library_paths = config.library_paths,
    };

    return &self.window;
}

pub fn readNativeScopeInterface(handle: *const anyopaque, row: u64) effects.Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);
    const declaration = &self.config().native_interfaces[index];

    configuration.validateInterface(declaration.specifier, declaration.path) catch |err| return self.failure.save(err);

    const path = resolveNativeScopePath(handle, declaration.path) catch |err| return self.failure.save(err);

    if (self.inputs) |observed| observed.add(self.io, path) catch |err| return self.failure.save(err);

    const source = @import("../../sources/text.zig").read(self.io, self.allocator, path, null) catch |err| return self.failure.save(err);

    if (self.inputs) |observed| observed.record(self.io, path, source.bytes) catch |err| return self.failure.save(err);

    self.native[index] = .{
        .specifier = declaration.specifier,
        .path = path,
        .source = source.bytes,
        .module = declaration.module,
        .namespace = declaration.namespace,
    };
}

pub fn prepareNativeScopeNames(handle: *const anyopaque) effects.Error!void {
    const self = State.get(handle);
    const config = self.config();
    self.legacy = self.allocator.dupe(compiler.project.External, config.externals) catch |err| return self.failure.save(err);
    self.name_memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&self.slots), self.allocator);

    self.names = configuration.bindNames(self.allocator, self.name_memory.allocator(), config.native_modules, .{
        .owner = self.scope().root,
        .entry_root = self.entry_root,
        .compiled = self.compiled != null,
    }) catch |err| return self.failure.save(err);
}

pub fn bindNativeScopeDeclaration(handle: *const anyopaque, row: u64, external: bool) effects.Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);

    if (external) {
        const declaration = &self.legacy[index];

        return bindDeclaration(self, declaration.specifier, &declaration.identity, &declaration.implementation.module);
    }

    const declaration = &self.native[index];

    return bindDeclaration(self, declaration.specifier, &declaration.identity, &declaration.module);
}

fn bindDeclaration(self: *State, specifier: []const u8, identity: *?[]const u8, module: *[]const u8) effects.Error!void {
    const owner = self.allocator;

    identity.* = (if (self.compiled) |binding|
        binding.declaration(owner, specifier)
    else
        configuration.declaration(owner, self.scope().root, specifier)) catch |err| return self.failure.save(err);

    module.* = self.names.?.name(owner, module.*) catch |err| return self.failure.save(err);
}

pub fn publishNativeScopeDeclarations(handle: *const anyopaque) effects.Error!void {
    const self = State.get(handle);
    const scope = self.scope();
    const owner = self.allocator;

    scope.native_interfaces = self.native;
    scope.externals = self.legacy;

    if (self.native.len != 0 or self.legacy.len != 0) {
        const exported = self.declarations.addManyAsSlice(owner, self.native.len) catch |err| return self.failure.save(err);
        const first = self.externals.items.len;

        self.externals.appendSlice(owner, self.legacy) catch |err| return self.failure.save(err);
        storage.declarations(self.native, self.legacy, exported, self.externals.items[first..]);
    }

    self.interfaces.appendSlice(owner, self.native) catch |err| return self.failure.save(err);
    self.libraries.appendSlice(owner, self.config().libraries) catch |err| return self.failure.save(err);
}

pub fn reserveNativeScopeLibraryPaths(handle: *const anyopaque) std.mem.Allocator.Error![]const []const u8 {
    const self = State.get(handle);

    return self.library_paths.addManyAsSlice(self.allocator, self.config().library_paths.len);
}

pub fn resolveNativeScopePath(handle: *const anyopaque, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const self = State.get(handle);

    return std.fs.path.resolve(self.allocator, &.{ self.scope().root, path });
}

pub fn reserveNativeScopeModules(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);

    self.module_first = self.modules.items.len;

    try self.modules.ensureUnusedCapacity(self.allocator, self.config().native_modules.len);
}

pub fn nativeScopeModulePaths(handle: *const anyopaque, row: u64) *const abi.ModulePaths {
    const self = State.get(handle);
    const config = self.config();
    const source = &config.native_modules[@intCast(row)];

    self.paths = .{ .path = source.path, .includes = source.include_paths orelse config.include_paths };

    return &self.paths;
}

pub fn prepareNativeScopeModule(handle: *const anyopaque, row: u64, path: ?[]const u8, includes: u64) effects.Error![]const []const u8 {
    const self = State.get(handle);
    const index: usize = @intCast(row);
    const names = &self.names.?;

    self.module = self.config().native_modules[index];
    self.module.name = names.resolved[index];
    self.module.path = path;
    self.module.dependencies = names.dependencies(self.allocator, self.module.dependencies) catch |err| return self.failure.save(err);

    return self.allocator.alloc([]const u8, @intCast(includes)) catch |err| return self.failure.save(err);
}

pub fn publishNativeScopeModule(handle: *const anyopaque, includes: []const []const u8) effects.Error!void {
    const self = State.get(handle);
    const owner = self.allocator;
    const module = &self.module;

    module.include_paths = includes;

    module.abi_aliases = (if (self.compiled) |binding|
        binding.aliases(owner, module.abi_aliases)
    else
        compiler.project.compiled.identity.sourceAliases(owner, self.native, self.legacy, @import("../../../package/manifest/model.zig").AbiAlias, module.abi_aliases)) catch |err| return self.failure.save(err);

    const previous = self.registry.register(self.registry_owner, module.name, self.modules.items.len) catch |err| return self.failure.save(err);

    if (previous != null) return self.failure.save(error.DuplicateNativeModule);

    self.modules.appendAssumeCapacity(module.*);
}

pub fn publishNativeScopeSettings(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const modules = self.modules.items[self.module_first..];

    if (modules.len == 0) return;

    const output = try self.settings.addManyAsSlice(self.allocator, modules.len);

    storage.settings(self.scope().root, self.config().include_paths, modules, output);
}

pub fn closeNativeScope(handle: *const anyopaque) void {
    State.get(handle).close();
}
