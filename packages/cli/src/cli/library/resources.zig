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
const Stage = @import("stage/storage.zig").State;

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
    inputs: ?*Inputs,
    failure: *effects.Failure,
    native_modules: []project.NativeModule = &.{},
    bundled_files: std.ArrayList(native_sources.File) = .empty,
    dependencies: []Dependency = &.{},
    external_includes: std.ArrayList([]const u8) = .empty,
    current: *project.NativeModule = undefined,
    dependency: *Dependency = undefined,
    root: []const u8 = undefined,
};

pub fn bindLibraryModule(handle: *const anyopaque, index: u64, root: []const u8, includes: []const []const u8) void {
    const self = &Stage.get(handle).resources;
    const row: usize = @intCast(index);
    const native = &self.native_modules[row];

    self.current = native;
    self.dependency = &self.dependencies[row];
    self.dependency.* = .{ .name = native.name, .header = native.header, .c_imports = native.header != null };
    self.root = root;
    native.include_paths = includes;
}

pub fn bundleNativeModule(handle: *const anyopaque, record_bundle: bool) Error![]const []const u8 {
    const self = &Stage.get(handle).resources;
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

pub fn addExternalIncludes(handle: *const anyopaque, paths: []const []const u8) Error!void {
    const self = &Stage.get(handle).resources;

    self.external_includes.appendSlice(self.allocator, paths) catch |err| return self.failure.save(err);
}

pub fn writeLibraryNativeHeader(handle: *const anyopaque) Error!void {
    const self = &Stage.get(handle).resources;

    const header = source.workspace_native_header.executeValue(self.allocator, &.{
        .directory = self.directory,
        .name = self.current.name,
        .header = self.current.header.?,
    }) catch |err| return self.failure.save(err);

    artifacts.write(self.io, header.path, header.source) catch |err| return self.failure.save(err);
}

pub fn writeLibraryNativeAdapter(handle: *const anyopaque) Error!void {
    const self = &Stage.get(handle).resources;
    const allocator = self.allocator;
    const path = source.workspace_native_path.executeIn(allocator, &.{ .directory = self.directory, .name = self.current.name, .extension = workspace.zig_extension }) catch |err| return self.failure.save(err);
    const adapter = compiler.zig.host.cAdapter(allocator) catch |err| return self.failure.save(err);

    defer allocator.free(adapter);
    artifacts.write(self.io, path, adapter) catch |err| return self.failure.save(err);
}
