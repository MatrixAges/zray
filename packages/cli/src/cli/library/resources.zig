const std = @import("std");
const compiler = @import("compiler");
const project = @import("../project.zig");
const artifacts = @import("../artifacts.zig");
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
    bundle: native_sources.Result = undefined,
    bundle_paths: [][]const u8 = &.{},
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
    self.module = .{ .name = native.name, .includes = native.include_paths };

    return &self.module;
}

pub fn bindLibraryModule(handle: *const anyopaque, root: []const u8, includes: []const []const u8) void {
    const self = effects.state(State, handle);

    self.root = root;
    self.current.include_paths = includes;
}

pub fn hasBundleInput(handle: *const anyopaque) bool {
    const native = effects.state(State, handle).current;

    return native.path != null or native.bundle_files.len != 0;
}

pub fn hasNativeHeader(handle: *const anyopaque) bool {
    return effects.state(State, handle).current.header != null;
}

pub fn bundleNativeModule(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const native = self.current;

    const bundled = native_sources.write(self.io, self.allocator, self.directory, self.root, .{
        .name = native.name,
        .path = native.path,
        .header = native.header,
        .bundle_files = native.bundle_files,
        .include_paths = native.include_paths.?,
    }, self.inputs) catch |err| return self.failure.save(err);

    self.bundle = bundled;
    native.path = bundled.entry;
    native.include_paths = bundled.include_paths;
    self.dependency.c_imports = bundled.c_imports;
    self.dependency.dynamic_resources = bundled.dynamic_resources;
    self.dependency.include_relocations = bundled.include_relocations;

    self.bundled_files.appendSlice(self.allocator, bundled.files) catch |err| return self.failure.save(err);
}

pub fn allocateBundlePaths(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    self.bundle_paths = self.allocator.alloc([]const u8, self.bundle.files.len) catch |err| return self.failure.save(err);
    self.current.bundle_files = self.bundle_paths;
}

pub fn bundleFileCount(handle: *const anyopaque) u64 {
    return effects.state(State, handle).bundle.files.len;
}

pub fn recordBundlePath(handle: *const anyopaque, index: u64) void {
    const self = effects.state(State, handle);
    const row: usize = @intCast(index);

    self.bundle_paths[row] = self.bundle.files[row].path;
}

pub fn nativeIncludes(handle: *const anyopaque) []const []const u8 {
    return effects.state(State, handle).current.include_paths.?;
}

pub fn addExternalInclude(handle: *const anyopaque, path: []const u8) Error!void {
    const self = effects.state(State, handle);

    self.external_includes.append(self.allocator, path) catch |err| return self.failure.save(err);
}

pub fn writeLibraryNativeHeader(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    writeHeader(self) catch |err| return self.failure.save(err);
}

fn writeHeader(self: *State) !void {
    const allocator = self.allocator;
    const path = try std.fmt.allocPrint(allocator, "{s}/native/{s}.h", .{ self.directory, self.current.name });
    const include = try std.json.Stringify.valueAlloc(allocator, self.current.header.?, .{});
    const source = try std.fmt.allocPrint(allocator, "#include {s}\n", .{include});

    try artifacts.write(self.io, path, source);
}

pub fn writeLibraryNativeAdapter(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    writeAdapter(self) catch |err| return self.failure.save(err);
}

fn writeAdapter(self: *State) !void {
    const allocator = self.allocator;
    const path = try std.fmt.allocPrint(allocator, "{s}/native/{s}.zig", .{ self.directory, self.current.name });
    const source = try compiler.zig.host.cAdapter(allocator);

    defer allocator.free(source);

    try artifacts.write(self.io, path, source);
}
