const std = @import("std");
const compiler = @import("compiler");
const aliases = @import("aliases.zig");
const State = @import("state.zig");
const effects = @import("../../sources/effects.zig");
const zx = @import("zx");
const memory = zx.memory;
const source_index = compiler.project.source_index;
const abi = @import("cli_abi").layouts.@"zig:native_scope_host";

pub fn openNativeScope(handle: *const anyopaque, index: u64) *const abi.ScopeWindow {
    const self = State.get(handle);

    self.current = @intCast(index);

    const config = self.config();
    const root = self.scope().root;

    self.externals_view = memory.borrowTextColumn("specifier", config.externals);
    self.external_rows = .{ .items = @ptrCast(&self.externals_view), .length = config.externals.len };
    self.owner = .{ .owner = root, .entry_root = self.entry_root, .compiled = false };

    self.window = .{
        .frame = @ptrCast(handle),
        .scope = &self.owner,
        .declarations = config.native_interfaces.len,
        .externals = config.externals.len,
        .modules = config.native_modules.len,
        .artifact = config.library,
        .library_paths = config.library_paths,
    };

    return &self.window;
}

pub fn openNativeScopeArtifact(handle: *const anyopaque, relative: []const u8) effects.Error!void {
    const self = State.get(handle);
    const root = self.scope().root;
    const path = std.fs.path.resolve(self.allocator, &.{ root, relative }) catch |err| return self.failure.save(err);

    defer self.allocator.free(path);

    self.compiled = @import("../../library/artifact.zig").open(std.heap.page_allocator, .{
        .io = self.io,
        .path = path,
        .scopes = self.scopes,
        .inputs = self.inputs,
    }) catch |err| return self.failure.save(err);

    self.compiled_modules = zx.columns.columns(aliases.Modules, self.compiled.?.program.native_modules);
    self.compiled_view = .{ .modules = &self.compiled_modules, .instance = root };
    self.owner.compiled = true;
}

pub fn requireNativeScopeAdmission(handle: *const anyopaque, status: abi.Admission) effects.Error!void {
    if (status == .Valid) return;

    return State.get(handle).failure.save(switch (status) {
        .Valid => unreachable,
        .InvalidSpecifier => error.InvalidSpecifier,
        .InvalidExternalSpecifier => error.InvalidExternalSpecifier,
        .InvalidNativeInterfacePath => error.InvalidNativeInterfacePath,
        .InvalidNativeModule => error.InvalidNativeModule,
        .ReservedNativeModule => error.ReservedNativeModule,
        .DuplicateNativeModule => error.DuplicateNativeModule,
        .UnknownNativeDependency => error.UnknownNativeDependency,
        .ConflictingNativeAbiAlias => error.ConflictingNativeAbiAlias,
        .UnknownNativeAbiAlias => error.UnknownNativeAbiAlias,
    });
}

pub fn reserveNativeScopeInterfaces(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);

    self.native = try self.allocator.alloc(compiler.project.NativeInterface, self.config().native_interfaces.len);
}

pub fn nativeScopeInterfacePath(handle: *const anyopaque, row: u64) *const abi.InterfacePath {
    const self = State.get(handle);
    const declaration = &self.config().native_interfaces[@intCast(row)];

    self.interface = .{ .specifier = declaration.specifier, .path = declaration.path };

    return &self.interface;
}

pub fn readNativeScopeInterface(handle: *const anyopaque, row: u64) effects.Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);
    const declaration = &self.config().native_interfaces[index];
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

pub fn reserveNativeScopeIndex(handle: *const anyopaque) effects.Error!void {
    const self = State.get(handle);
    const config = self.config();
    const modules = config.native_modules;

    self.legacy = self.allocator.dupe(compiler.project.External, config.externals) catch |err| return self.failure.save(err);
    self.name_memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&self.slots), self.allocator);
    self.buckets = source_index.Map.bucketsFor(self.name_memory.allocator(), modules.len) catch |err| return self.failure.save(err);
    self.names_view = memory.borrowTextColumn("name", modules);
    self.path_view = memory.borrowReadColumn(?[]const u8, "path", modules);
    self.header_view = memory.borrowReadColumn(?[]const u8, "header", modules);
    self.index = .{ .names = @ptrCast(&self.names_view), .buckets = @ptrCast(&self.buckets), .capacity = self.buckets.len };

    self.module_rows = .{
        .index = &self.index,
        .count = modules.len,
        .paths = @ptrCast(&self.path_view),
        .headers = @ptrCast(&self.header_view),
    };
}

pub fn reserveNativeScopeNames(handle: *const anyopaque) std.mem.Allocator.Error!*abi.ScopeTextSlots {
    const self = State.get(handle);

    self.names = try self.name_memory.allocator().alloc([]const u8, self.config().native_modules.len);
    self.naming_index = .{ .names = @ptrCast(&self.names_view), .buckets = @ptrCast(&self.buckets), .capacity = self.buckets.len };
    self.registry_view = .{ .index = &self.naming_index, .names = self.names };

    return @ptrCast(self.names.ptr);
}

pub fn nativeScopeDeclaration(handle: *const anyopaque, row: u64, external: bool) *const abi.DeclarationBinding {
    const self = State.get(handle);
    const index: usize = @intCast(row);

    if (external) {
        const declaration = &self.legacy[index];

        self.declaration = .{ .specifier = declaration.specifier, .module = declaration.implementation.module };
    } else {
        const declaration = &self.native[index];

        self.declaration = .{ .specifier = declaration.specifier, .module = declaration.module };
    }

    return &self.declaration;
}

pub fn writeNativeScopeDeclaration(handle: *const anyopaque, row: u64, external: bool, identity: []const u8, module: []const u8) void {
    const self = State.get(handle);
    const index: usize = @intCast(row);

    if (external) {
        const declaration = &self.legacy[index];
        declaration.identity = identity;
        declaration.implementation.module = module;
    } else {
        const declaration = &self.native[index];
        declaration.identity = identity;
        declaration.module = module;
    }
}

pub fn reserveNativeScopeDeclarations(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const scope = self.scope();
    const owner = self.allocator;
    scope.native_interfaces = self.native;
    scope.externals = self.legacy;
    const exported = try self.declarations.addManyAsSlice(owner, self.native.len);
    const first = self.externals.items.len;

    try self.externals.appendSlice(owner, self.legacy);

    self.declaration_views.init(self.native, self.legacy, exported, self.externals.items[first..]);

    if (self.compiled == null and self.config().native_modules.len != 0) {
        self.alias_native.init(self.native);
        self.alias_external.init(self.legacy);

        self.alias_declarations = .{ .interfaces = &self.alias_native.view, .externals = &self.alias_external.view };
    }
}

pub fn finishNativeScopeDeclarations(handle: *const anyopaque) effects.Error!void {
    const self = State.get(handle);
    const owner = self.allocator;

    self.interfaces.appendSlice(owner, self.native) catch |err| return self.failure.save(err);
    self.libraries.appendSlice(owner, self.config().libraries) catch |err| return self.failure.save(err);
}

pub fn reserveNativeScopeLibraryPaths(handle: *const anyopaque) std.mem.Allocator.Error!*abi.ScopeTextSlots {
    const self = State.get(handle);
    const items = try self.library_paths.addManyAsSlice(self.allocator, self.config().library_paths.len);

    return @ptrCast(items.ptr);
}

pub fn writeNativeScopeText(target: *anyopaque, index: u64, value: []const u8) void {
    const items: [*][]const u8 = @ptrCast(@alignCast(target));

    items[@intCast(index)] = value;
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

    self.paths = .{
        .path = source.path,
        .includes = source.include_paths orelse config.include_paths,
        .dependencies = source.dependencies,
    };

    return &self.paths;
}

pub fn prepareNativeScopeModule(handle: *const anyopaque, row: u64, name: []const u8, path: ?[]const u8, dependencies: []const []const u8, includes: u64) std.mem.Allocator.Error!*abi.ScopeTextSlots {
    const self = State.get(handle);
    const index: usize = @intCast(row);

    self.module = self.config().native_modules[index];
    self.module.name = name;
    self.module.path = path;
    self.module.dependencies = dependencies;

    const allocated = try self.allocator.alloc([]const u8, @intCast(includes));

    self.module.include_paths = allocated;

    return @ptrCast(allocated.ptr);
}

pub fn prepareNativeScopeAliases(handle: *const anyopaque) void {
    const self = State.get(handle);
    const configured = self.module.abi_aliases;

    self.alias_storage.init(configured);

    self.alias_input = .{
        .compiled = if (self.compiled != null) &self.compiled_view else null,
        .source = if (self.compiled == null) &self.alias_declarations else null,
        .configured = if (configured != null) &self.alias_storage.configured else null,
        .output = &self.alias_storage.output,
    };

    self.alias_active = true;
    self.active.active = self.allocator;
}

pub fn publishNativeScopeModule(handle: *const anyopaque) effects.Error!void {
    const self = State.get(handle);
    const module = &self.module;

    module.abi_aliases = self.alias_storage.rows.rows();
    self.alias_active = false;
    self.active.active = self.scratch;

    const previous = self.registry.register(self.registry_owner, module.name, self.modules.items.len) catch |err| return self.failure.save(err);

    if (previous != null) return self.failure.save(error.DuplicateNativeModule);

    self.modules.appendAssumeCapacity(module.*);
}

pub fn reserveNativeScopeSettings(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const modules = self.modules.items[self.module_first..];
    const output = try self.settings.addManyAsSlice(self.allocator, modules.len);

    self.setting_views.init(self.scope().root, self.config().include_paths, modules, output);
}

pub fn closeNativeScope(handle: *const anyopaque) void {
    State.get(handle).close();
}
