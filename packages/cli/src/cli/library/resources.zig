const std = @import("std");
const compiler = @import("compiler");
const project = @import("../project.zig");
const artifacts = @import("../artifacts.zig");
const source = @import("cli_source");
const workspace = source.workspace_artifact_constants.@"zx.constants";
const native_sources = @import("native_resource_host");
const Inputs = @import("watch_inputs").Inputs;
const effects = @import("publication_host").effects;
const Error = effects.Error;
const Module = @import("cli_abi").layouts.@"zig:library_stage_host".LibraryNativeModule;

pub const Dependency = struct {
    name: []const u8,
    header: ?[]const u8,
    c_imports: bool = false,
    dynamic_resources: bool = false,
    include_relocations: []const native_sources.Include = &.{},
};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    loaded: *const project.Loaded,
    inputs: ?*Inputs,
    failure: *effects.Failure,
    native_modules: []project.NativeModule = &.{},
    library_paths: []const []const u8 = &.{},
    bundled_files: std.ArrayList(native_sources.File) = .empty,
    dependencies: []Dependency = &.{},
    external_includes: std.ArrayList([]const u8) = .empty,
    current: *project.NativeModule = undefined,
    dependency: *Dependency = undefined,
    root: []const u8 = undefined,
    module: Module = undefined,
};

pub fn allocateNativeRows(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const modules = self.loaded.config.native_modules;
    self.native_modules = self.allocator.dupe(project.NativeModule, modules) catch |err| return self.failure.save(err);
    self.dependencies = self.allocator.alloc(Dependency, modules.len) catch |err| return self.failure.save(err);
}

pub fn bindLibraryPaths(handle: *const anyopaque, paths: []const []const u8) void {
    effects.state(State, handle).library_paths = paths;
}

pub fn libraryNativeModule(handle: *const anyopaque, index: u64) *const Module {
    const self = effects.state(State, handle);
    const row: usize = @intCast(index);
    const native = &self.native_modules[row];

    self.current = native;
    self.dependency = &self.dependencies[row];
    self.dependency.* = .{ .name = native.name, .header = native.header, .c_imports = native.header != null };

    self.module = .{
        .name = native.name,
        .includes = native.include_paths,
        .has_bundle = native.path != null or native.bundle_files.len != 0,
        .has_header = native.header != null,
    };

    return &self.module;
}

pub fn bindLibraryModule(handle: *const anyopaque, root: []const u8, includes: []const []const u8) void {
    const self = effects.state(State, handle);

    self.root = root;
    self.current.include_paths = includes;
}

pub fn bundleNativeModule(handle: *const anyopaque, record_bundle: bool) Error![]const []const u8 {
    const self = effects.state(State, handle);
    const native = self.current;

    const bundled = native_sources.write(self.io, self.allocator, self.directory, self.root, .{
        .name = native.name,
        .path = native.path,
        .header = native.header,
        .bundle_files = native.bundle_files,
        .include_paths = native.include_paths.?,
    }, self.inputs) catch |err| return self.failure.save(err);

    native.path = bundled.entry;
    native.include_paths = bundled.include_paths;
    self.dependency.c_imports = bundled.c_imports;
    self.dependency.dynamic_resources = bundled.dynamic_resources;
    self.dependency.include_relocations = bundled.include_relocations;

    self.bundled_files.appendSlice(self.allocator, bundled.files) catch |err| return self.failure.save(err);

    if (record_bundle) {
        const paths = self.allocator.alloc([]const u8, bundled.files.len) catch |err| return self.failure.save(err);

        for (bundled.files, 0..) |file, index| {
            paths[index] = file.path;
        }

        native.bundle_files = paths;
    }

    return bundled.include_paths;
}

pub fn addExternalInclude(handle: *const anyopaque, path: []const u8) Error!void {
    const self = effects.state(State, handle);

    self.external_includes.append(self.allocator, path) catch |err| return self.failure.save(err);
}

pub fn writeLibraryNativeHeader(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    const header = source.workspace_native_header.executeValue(self.allocator, &.{
        .directory = self.directory,
        .name = self.current.name,
        .header = self.current.header.?,
    }) catch |err| return self.failure.save(err);

    artifacts.write(self.io, header.path, header.source) catch |err| return self.failure.save(err);
}

pub fn writeLibraryNativeAdapter(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const allocator = self.allocator;
    const path = source.workspace_native_path.executeIn(allocator, &.{ .directory = self.directory, .name = self.current.name, .extension = workspace.zig_extension }) catch |err| return self.failure.save(err);
    const adapter = compiler.zig.host.cAdapter(allocator) catch |err| return self.failure.save(err);

    defer allocator.free(adapter);
    artifacts.write(self.io, path, adapter) catch |err| return self.failure.save(err);
}
