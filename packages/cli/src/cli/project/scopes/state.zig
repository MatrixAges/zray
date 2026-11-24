const std = @import("std");
const compiler = @import("compiler");
const effects = @import("../../sources/effects.zig");
const CompiledNative = @import("../compiled_native.zig");
const Inputs = @import("watch_inputs").Inputs;
const model = @import("../../../package/manifest/model.zig");
const memory = @import("zx").memory;
const storage = @import("publish.zig");
const abi = @import("cli_abi").layouts.@"zig:native_scope_host";
const Self = @This();
const name_workspace_slots = 32;
const Request = std.meta.Child(@typeInfo(@import("cli_source").native_scope_load.Input).optional.child);
const Workspace = std.meta.Child(@FieldType(Request, "workspace"));
const Modules = std.meta.Child(@FieldType(Workspace, "modules"));
const Binding = std.meta.Child(@FieldType(Workspace, "binding"));
pub const Result = struct { config: model.Manifest, interfaces: []const compiler.project.NativeInterface, settings: []const storage.NativeSettings };

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
settings: std.ArrayList(storage.NativeSettings) = .empty,
libraries: std.ArrayList([]const u8) = .empty,
library_paths: std.ArrayList([]const u8) = .empty,
registry: compiler.project.source_index.Owned = .{},
current: usize = undefined,
compiled: ?CompiledNative = null,
native: []compiler.project.NativeInterface = undefined,
legacy: []compiler.project.External = undefined,
slots: [name_workspace_slots][]const u8 = undefined,
name_memory: std.heap.BufferFirstAllocator = undefined,
names: [][]const u8 = &.{},
buckets: []u64 = &.{},
externals_view: memory.TextColumn = undefined,
names_view: memory.TextColumn = undefined,
path_view: memory.ReadColumn = undefined,
header_view: memory.ReadColumn = undefined,
index: std.meta.Child(@FieldType(Modules, "index")) = undefined,
workspace: Workspace = undefined,
binding: Binding = undefined,
registry_view: std.meta.Child(@FieldType(Binding, "registry")) = undefined,
external_rows: std.meta.Child(@FieldType(Workspace, "externals")) = undefined,
module_rows: Modules = undefined,
owner: abi.ScopeOwner = undefined,
window: abi.ScopeWindow = undefined,
paths: abi.ModulePaths = undefined,
interface: abi.InterfacePath = undefined,
declaration: abi.DeclarationBinding = undefined,
module: model.NativeModule = undefined,
module_first: usize = undefined,
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
    result.config.library_paths = try self.library_paths.toOwnedSlice(owner);
    result.interfaces = try self.interfaces.toOwnedSlice(owner);
    result.settings = try self.settings.toOwnedSlice(owner);

    return result;
}
