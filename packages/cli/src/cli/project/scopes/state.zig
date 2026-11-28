const std = @import("std");
const compiler = @import("compiler");
const effects = @import("../../sources/effects.zig");
const aliases = @import("aliases.zig");
const Inputs = @import("watch_inputs").Inputs;
const model = @import("../../../package/manifest/model.zig");
const memory = @import("zx").memory;
const projections = @import("projections.zig");
const abi = @import("cli_abi").layouts.@"zig:native_scope_host";
const Self = @This();
const name_workspace_slots = 32;
const Entry = @import("cli_source").native_scope_load;
const Request = std.meta.Child(Entry.Input);
pub const Publication = std.meta.Child(@FieldType(Entry.zx_pending, "store_0"));
const Workspace = std.meta.Child(@FieldType(Request, "workspace"));
const Modules = std.meta.Child(@FieldType(Workspace, "modules"));
const Binding = std.meta.Child(@FieldType(Workspace, "binding"));
const Traversal = std.meta.Child(@FieldType(Workspace, "traversal"));
pub const NativeSettings = projections.NativeSettings;
pub const Result = struct { config: model.Manifest, interfaces: []const compiler.project.NativeInterface, settings: []const NativeSettings };

io: std.Io,
allocator: std.mem.Allocator,
inputs: ?*Inputs,
scopes: []compiler.project.PackageScope,
manifests: []const model.Manifest,
entry_root: []const u8,
registry_owner: std.mem.Allocator,
failure: effects.Failure = .{},
modules: std.ArrayList(model.NativeModule) = .empty,
declarations: std.ArrayList(model.NativeInterface) = .empty,
interfaces: std.ArrayList(compiler.project.NativeInterface) = .empty,
externals: std.ArrayList(compiler.project.External) = .empty,
libraries: std.ArrayList([]const u8) = .empty,
library_paths: std.ArrayList([]const u8) = .empty,
settings: std.ArrayList(NativeSettings) = .empty,
registry: compiler.project.source_index.Owned = .{},
current: usize = undefined,
compiled: ?compiler.library.Result = null,
compiled_modules: aliases.Modules = undefined,
compiled_view: aliases.Compiled = undefined,
alias_declarations: aliases.Declarations = undefined,
alias_native: aliases.Rows = undefined,
alias_external: aliases.Rows = undefined,
alias_input: aliases.Input = undefined,
alias_configured: aliases.Configuration = undefined,
alias_active: bool = false,
native: []compiler.project.NativeInterface = undefined,
legacy: []compiler.project.External = undefined,
slots: [name_workspace_slots][]const u8 = undefined,
name_memory: std.heap.BufferFirstAllocator = undefined,
names: [][]const u8 = &.{},
buckets: []u64 = &.{},
externals_view: memory.TextColumn = undefined,
external_modules: memory.TextColumn = undefined,
interface_specifiers: memory.TextColumn = undefined,
interface_paths: memory.TextColumn = undefined,
interface_modules: memory.TextColumn = undefined,
names_view: memory.TextColumn = undefined,
path_view: memory.ReadColumn = undefined,
header_view: memory.ReadColumn = undefined,
module_includes: memory.ReadColumn = undefined,
module_dependencies: memory.ReadColumn = undefined,
module_sources: std.meta.Child(@FieldType(Traversal, "sources")) = undefined,
naming_index: std.meta.Child(@FieldType(std.meta.Child(@FieldType(Binding, "registry")), "index")) = undefined,
workspace: Workspace = undefined,
binding: Binding = undefined,
traversal: Traversal = undefined,
declaration_views: projections.Declarations = undefined,
registry_view: std.meta.Child(@FieldType(Binding, "registry")) = undefined,
external_rows: std.meta.Child(@FieldType(Workspace, "externals")) = undefined,
interface_rows: std.meta.Child(@FieldType(Workspace, "interfaces")) = undefined,
module_rows: Modules = undefined,
owner: abi.ScopeOwner = undefined,
window: abi.ScopeWindow = undefined,
pub fn get(handle: *const anyopaque) *Self {
    return effects.state(Self, handle);
}

pub fn config(self: *const Self) *const model.Manifest {
    return &self.manifests[self.current];
}

pub fn scope(self: *const Self) *compiler.project.PackageScope {
    return &self.scopes[self.current];
}

pub fn close(self: *Self) void {
    self.alias_active = false;

    if (self.names.len != 0 or self.buckets.len != 0) {
        const temporary = self.name_memory.allocator();

        temporary.free(self.names);
        temporary.free(self.buckets);

        self.names = &.{};
        self.buckets = &.{};
    }

    if (self.compiled) |*binding| {
        binding.deinit();

        self.compiled = null;
    }
}

pub fn take(self: *Self, config_value: model.Manifest) !Result {
    const owner = self.allocator;
    var result = Result{ .config = config_value, .interfaces = &.{}, .settings = &.{} };

    result.config.native_modules = try self.modules.toOwnedSlice(owner);
    result.config.native_interfaces = try self.declarations.toOwnedSlice(owner);
    result.config.externals = try self.externals.toOwnedSlice(owner);
    result.config.libraries = try self.libraries.toOwnedSlice(owner);
    result.interfaces = try self.interfaces.toOwnedSlice(owner);
    result.config.library_paths = try self.library_paths.toOwnedSlice(owner);
    result.settings = try self.settings.toOwnedSlice(owner);

    return result;
}

pub fn publish(self: *Self, value: Publication) std.mem.Allocator.Error!void {
    const allocator = self.allocator;

    try self.library_paths.ensureUnusedCapacity(allocator, value.paths.len);
    for (value.paths) |path| self.library_paths.appendAssumeCapacity(try allocator.dupe(u8, path));

    const settings = try self.settings.addManyAsSlice(allocator, value.settings.len);

    for (value.settings, settings) |item, *setting| {
        setting.* = .{ .name = item.name, .root = item.root, .include_paths = item.includes };
    }
}
