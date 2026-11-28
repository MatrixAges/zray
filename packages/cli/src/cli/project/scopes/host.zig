const std = @import("std");
const compiler = @import("compiler");
const aliases = @import("aliases.zig");
const Alias = @import("../../../package/manifest/model.zig").AbiAlias;
const State = @import("state.zig");
const effects = @import("../../sources/effects.zig");
const zx = @import("zx");
const memory = zx.memory;
const abi = @import("cli_abi").layouts.@"zig:native_scope_host";

pub fn openNativeScope(handle: *const anyopaque, index: u64) *const abi.ScopeWindow {
    const self = State.get(handle);

    self.current = @intCast(index);

    const config = self.config();
    const root = self.scope().root;

    self.externals_view = memory.borrowTextColumn("specifier", config.externals);
    self.external_modules = memory.borrowNestedColumn([]const u8, &.{ "implementation", "module" }, config.externals);
    self.external_rows = .{ .items = @ptrCast(&self.externals_view), .length = config.externals.len };
    self.interface_specifiers = memory.borrowTextColumn("specifier", config.native_interfaces);
    self.interface_paths = memory.borrowTextColumn("path", config.native_interfaces);
    self.interface_modules = memory.borrowTextColumn("module", config.native_interfaces);

    self.interface_rows = .{
        .specifiers = @ptrCast(&self.interface_specifiers),
        .paths = @ptrCast(&self.interface_paths),
        .modules = @ptrCast(&self.interface_modules),
    };

    borrowModules(self, config.native_modules, config.include_paths);

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

pub fn openNativeScopeArtifact(handle: *const anyopaque, path: []const u8) effects.Error!void {
    const self = State.get(handle);
    const root = self.scope().root;

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

pub fn reserveNativeScopeInterfaces(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const self = State.get(handle);

    self.native = try self.allocator.alloc(compiler.project.NativeInterface, self.config().native_interfaces.len);

    self.declaration_views.init(self.native);
}

pub fn readNativeScopeInterface(handle: *const anyopaque, row: u64) effects.Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);
    const declaration = &self.config().native_interfaces[index];
    const path = std.fs.path.resolve(self.allocator, &.{ self.scope().root, declaration.path }) catch |err| return self.failure.save(err);

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

fn borrowModules(self: *State, modules: []const @import("../../../package/manifest/model.zig").NativeModule, default_includes: []const []const u8) void {
    self.names_view = memory.borrowTextColumn("name", modules);
    self.path_view = memory.borrowReadColumn(?[]const u8, "path", modules);
    self.header_view = memory.borrowReadColumn(?[]const u8, "header", modules);
    self.module_includes = memory.borrowReadColumn(?[]const []const u8, "include_paths", modules);
    self.module_dependencies = memory.borrowReadColumn([]const []const u8, "dependencies", modules);

    self.module_sources = .{
        .paths = @ptrCast(&self.path_view),
        .includes = @ptrCast(&self.module_includes),
        .dependencies = @ptrCast(&self.module_dependencies),
        .default_includes = default_includes,
    };

    self.module_rows = .{
        .names = @ptrCast(&self.names_view),
        .count = modules.len,
        .paths = @ptrCast(&self.path_view),
        .headers = @ptrCast(&self.header_view),
    };
}

pub fn publishNativeScopeNames(handle: *const anyopaque, buckets: []const u64, names: []const []const u8) std.mem.Allocator.Error!void {
    const self = State.get(handle);

    self.name_memory = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&self.slots), self.allocator);

    const temporary = self.name_memory.allocator();

    self.buckets = if (buckets.len == 0) &.{} else try temporary.dupe(u64, buckets);
    self.names = if (names.len == 0) &.{} else try temporary.alloc([]const u8, names.len);

    for (names, 0..) |name, i| self.names[i] = try dupeText(self.allocator, name);

    self.naming_index = .{ .names = @ptrCast(&self.names_view), .buckets = @ptrCast(&self.buckets), .capacity = self.buckets.len };
    self.registry_view = .{ .index = &self.naming_index, .names = self.names };
}

pub fn finishNativeScopeDeclarations(handle: *const anyopaque, declarations: []const *const abi.PublishedDeclaration, externals: []const []const u8, bindings: []const *const abi.Resolved) effects.Error!void {
    const self = State.get(handle);
    const owner = self.allocator;
    const scope = self.scope();

    for (self.native, declarations, bindings[0..declarations.len]) |*declaration, published, binding| {
        declaration.identity = dupeText(owner, published.specifier) catch |err| return self.failure.save(err);
        declaration.module = ownedModule(owner, published.module, binding.copy_module) catch |err| return self.failure.save(err);
    }

    self.legacy = owner.dupe(compiler.project.External, self.config().externals) catch |err| return self.failure.save(err);

    for (self.legacy, externals, bindings[declarations.len..]) |*declaration, specifier, binding| {
        declaration.identity = dupeText(owner, specifier) catch |err| return self.failure.save(err);
        declaration.implementation.module = ownedModule(owner, binding.module, binding.copy_module) catch |err| return self.failure.save(err);
    }

    if (self.compiled == null and self.config().native_modules.len != 0) {
        self.alias_native.init(self.native);
        self.alias_external.init(self.legacy);

        self.alias_declarations = .{ .interfaces = &self.alias_native.view, .externals = &self.alias_external.view };
    }

    scope.native_interfaces = self.native;
    scope.externals = self.legacy;

    const exported = self.declarations.addManyAsSlice(owner, declarations.len) catch |err| return self.failure.save(err);

    for (declarations, self.native, exported) |item, native, *published| {
        published.* = .{
            .specifier = native.identity.?,
            .path = item.path,
            .module = native.module,
            .namespace = item.namespace,
        };
    }

    const published_externals = self.externals.addManyAsSlice(owner, externals.len) catch |err| return self.failure.save(err);

    for (self.legacy, published_externals) |item, *published| {
        var copy = item;
        copy.specifier = item.identity.?;
        copy.identity = null;
        published.* = copy;
    }

    self.interfaces.appendSlice(owner, self.native) catch |err| return self.failure.save(err);
    self.libraries.appendSlice(owner, self.config().libraries) catch |err| return self.failure.save(err);
}

pub fn prepareNativeScopeAliases(handle: *const anyopaque, row: u64) void {
    const self = State.get(handle);
    const configured = self.config().native_modules[@intCast(row)].abi_aliases;

    if (configured) |entries| self.alias_configured.init(entries);

    self.alias_input = .{
        .compiled = if (self.compiled != null) &self.compiled_view else null,
        .source = if (self.compiled == null) &self.alias_declarations else null,
        .configured = if (configured != null) &self.alias_configured.view else null,
    };

    self.alias_active = true;
}

pub fn publishNativeScopeModule(handle: *const anyopaque, row: u64, prepared: *const abi.PreparedModule, names: []const []const u8, specifiers: []const []const u8) effects.Error!void {
    const self = State.get(handle);
    var module = self.config().native_modules[@intCast(row)];
    const allocator = self.allocator;
    module.name = prepared.name;
    module.path = if (prepared.path) |path| dupeText(allocator, path) catch |err| return self.failure.save(err) else null;
    module.dependencies = ownStrings(allocator, prepared.dependencies) catch |err| return self.failure.save(err);
    module.include_paths = ownStrings(allocator, prepared.includes) catch |err| return self.failure.save(err);
    const previous = self.registry.register(self.registry_owner, module.name, self.modules.items.len) catch |err| return self.failure.save(err);

    if (previous != null) return self.failure.save(error.DuplicateNativeModule);

    module.abi_aliases = ownAliases(self.allocator, names, specifiers, self.compiled != null, module.abi_aliases == null) catch |err| return self.failure.save(err);
    self.alias_active = false;

    self.modules.append(self.allocator, module) catch |err| return self.failure.save(err);
}

fn ownStrings(allocator: std.mem.Allocator, strings: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (strings.len == 0) return &.{};

    const owned = try allocator.alloc([]const u8, strings.len);

    for (strings, owned) |text, *slot| slot.* = try dupeText(allocator, text);

    return owned;
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

pub fn closeNativeScope(handle: *const anyopaque) void {
    State.get(handle).close();
}

fn ownedModule(allocator: std.mem.Allocator, module: []const u8, copy: bool) std.mem.Allocator.Error![]const u8 {
    return if (copy) try dupeText(allocator, module) else module;
}

fn dupeText(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return if (value.len == 0) "" else allocator.dupe(u8, value);
}
