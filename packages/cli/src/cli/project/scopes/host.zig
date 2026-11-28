const std = @import("std");
const compiler = @import("compiler");
const aliases = @import("aliases.zig");
const Alias = @import("../../../package/manifest/model.zig").AbiAlias;
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
    self.interface_specifiers = memory.borrowTextColumn("specifier", config.native_interfaces);
    self.interface_paths = memory.borrowTextColumn("path", config.native_interfaces);
    self.interface_rows = .{ .specifiers = @ptrCast(&self.interface_specifiers), .paths = @ptrCast(&self.interface_paths) };
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

    const capacity = if (modules.len == 0) 0 else blk: {
        const desired = std.math.mul(usize, modules.len, 2) catch return self.failure.save(error.OutOfMemory);

        break :blk std.math.ceilPowerOfTwo(usize, desired) catch return self.failure.save(error.OutOfMemory);
    };

    self.names_view = memory.borrowTextColumn("name", modules);
    self.path_view = memory.borrowReadColumn(?[]const u8, "path", modules);
    self.header_view = memory.borrowReadColumn(?[]const u8, "header", modules);
    self.module_includes = memory.borrowReadColumn(?[]const []const u8, "include_paths", modules);
    self.module_dependencies = memory.borrowReadColumn([]const []const u8, "dependencies", modules);

    self.module_sources = .{
        .paths = @ptrCast(&self.path_view),
        .includes = @ptrCast(&self.module_includes),
        .dependencies = @ptrCast(&self.module_dependencies),
        .default_includes = config.include_paths,
    };

    self.index = .{ .names = @ptrCast(&self.names_view), .capacity = capacity };

    self.module_rows = .{
        .index = &self.index,
        .count = modules.len,
        .paths = @ptrCast(&self.path_view),
        .headers = @ptrCast(&self.header_view),
    };
}

pub fn publishNativeScopeNames(handle: *const anyopaque, buckets: []const u64, names: []const []const u8) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const temporary = self.name_memory.allocator();

    self.buckets = if (buckets.len == 0) &.{} else try temporary.dupe(u64, buckets);
    self.names = if (names.len == 0) &.{} else try temporary.alloc([]const u8, names.len);

    for (names, 0..) |name, i| self.names[i] = try dupeText(self.allocator, name);

    self.naming_index = .{ .names = @ptrCast(&self.names_view), .buckets = @ptrCast(&self.buckets), .capacity = self.buckets.len };
    self.registry_view = .{ .index = &self.naming_index, .names = self.names };
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

pub fn writeNativeScopeDeclaration(handle: *const anyopaque, row: u64, external: bool, identity: []const u8, module: []const u8, copy_module: bool) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);
    const owned_identity = try dupeText(self.allocator, identity);
    const owned_module = if (copy_module) try dupeText(self.allocator, module) else module;

    if (external) {
        const declaration = &self.legacy[index];
        declaration.identity = owned_identity;
        declaration.implementation.module = owned_module;
    } else {
        const declaration = &self.native[index];

        declaration.identity = owned_identity;
        declaration.module = owned_module;
    }
}

pub fn reserveNativeScopeDeclarations(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);

    self.declaration_views.init(self.native, self.legacy);

    if (self.compiled == null and self.config().native_modules.len != 0) {
        self.alias_native.init(self.native);
        self.alias_external.init(self.legacy);

        self.alias_declarations = .{ .interfaces = &self.alias_native.view, .externals = &self.alias_external.view };
    }
}

pub fn finishNativeScopeDeclarations(handle: *const anyopaque, declarations: []const *const abi.PublishedDeclaration, externals: []const []const u8) effects.Error!void {
    const self = State.get(handle);
    const owner = self.allocator;
    const scope = self.scope();

    scope.native_interfaces = self.native;
    scope.externals = self.legacy;

    const exported = self.declarations.addManyAsSlice(owner, declarations.len) catch |err| return self.failure.save(err);

    for (declarations, 0..) |item, i| {
        exported[i] = .{
            .specifier = item.specifier,
            .path = item.path,
            .module = item.module,
            .namespace = item.namespace,
        };
    }

    const published_externals = self.externals.addManyAsSlice(owner, externals.len) catch |err| return self.failure.save(err);

    for (self.legacy, externals, 0..) |item, specifier, i| {
        var copy = item;
        copy.specifier = specifier;
        copy.identity = null;
        published_externals[i] = copy;
    }

    self.interfaces.appendSlice(owner, self.native) catch |err| return self.failure.save(err);
    self.libraries.appendSlice(owner, self.config().libraries) catch |err| return self.failure.save(err);
}

pub fn publishNativeScopeLibraryPaths(handle: *const anyopaque, paths: []const []const u8) std.mem.Allocator.Error!void {
    const self = State.get(handle);

    try self.library_paths.appendSlice(self.allocator, paths);
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

pub fn prepareNativeScopeModule(handle: *const anyopaque, row: u64, name: []const u8, path: ?[]const u8, dependencies: []const []const u8, includes: []const []const u8) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);

    self.module = self.config().native_modules[index];
    self.module.name = name;
    self.module.path = path;

    if (dependencies.len == 0) {
        self.module.dependencies = &.{};
    } else {
        const deps = try self.allocator.alloc([]const u8, dependencies.len);

        for (dependencies, 0..) |dep, i| deps[i] = try dupeText(self.allocator, dep);

        self.module.dependencies = deps;
    }

    self.module.include_paths = if (includes.len == 0) &.{} else try self.allocator.dupe([]const u8, includes);
}

pub fn prepareNativeScopeAliases(handle: *const anyopaque) void {
    const self = State.get(handle);
    const configured = self.module.abi_aliases;

    if (configured) |entries| self.alias_configured.init(entries);

    self.alias_input = .{
        .compiled = if (self.compiled != null) &self.compiled_view else null,
        .source = if (self.compiled == null) &self.alias_declarations else null,
        .configured = if (configured != null) &self.alias_configured.view else null,
    };

    self.alias_active = true;
}

pub fn publishNativeScopeModule(handle: *const anyopaque, names: []const []const u8, specifiers: []const []const u8) effects.Error!void {
    const self = State.get(handle);
    const module = &self.module;
    const previous = self.registry.register(self.registry_owner, module.name, self.modules.items.len) catch |err| return self.failure.save(err);

    if (previous != null) return self.failure.save(error.DuplicateNativeModule);

    module.abi_aliases = ownAliases(self.allocator, names, specifiers, self.compiled != null, module.abi_aliases == null) catch |err| return self.failure.save(err);
    self.alias_active = false;

    self.modules.appendAssumeCapacity(module.*);
}

fn ownAliases(allocator: std.mem.Allocator, names: []const []const u8, specifiers: []const []const u8, compiled: bool, implicit_names: bool) std.mem.Allocator.Error![]const Alias {
    const copy_names = compiled and implicit_names;
    const rows = try allocator.alloc(Alias, names.len);
    var initialized: usize = 0;

    errdefer {
        for (rows[0..initialized]) |row| {
            if (copy_names) allocator.free(row.name);
            if (compiled) allocator.free(row.specifier);
        }

        allocator.free(rows);
    }

    for (names, specifiers, rows) |name, specifier, *row| {
        const stable_name = if (copy_names) try dupeText(allocator, name) else name;

        errdefer if (copy_names) allocator.free(stable_name);

        row.* = .{
            .name = stable_name,
            .specifier = if (compiled) try dupeText(allocator, specifier) else specifier,
        };

        initialized += 1;
    }

    return rows;
}

pub fn reserveNativeScopeSettings(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const modules = self.modules.items[self.module_first..];

    self.setting_views.init(self.scope().root, self.config().include_paths, modules);
}

pub fn publishNativeScopeSettings(handle: *const anyopaque, rows: []const *const abi.PublishedSetting) std.mem.Allocator.Error!void {
    const self = State.get(handle);
    const output = try self.settings.addManyAsSlice(self.allocator, rows.len);

    for (rows, 0..) |row, i| {
        output[i] = .{
            .name = row.name,
            .root = row.root,
            .include_paths = row.includes,
        };
    }
}

pub fn closeNativeScope(handle: *const anyopaque) void {
    State.get(handle).close();
}

fn dupeText(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return if (value.len == 0) "" else allocator.dupe(u8, value);
}
