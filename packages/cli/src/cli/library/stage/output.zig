const std = @import("std");
const compiler = @import("compiler");
const artifacts = @import("../../artifacts.zig");
const inventory = @import("publication_host").inventory;
const constants = @import("cli_source").library_publication_constants.@"zx.constants";
const FileGroup = @import("cli_abi").native.@"zig:library_stage_host".FileGroup;
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;

pub fn writeStageArtifact(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    writeArtifact(self) catch |err| return self.failure.save(err);
}

fn writeArtifact(self: *State) !void {
    const request = self.request;
    const path = try std.fs.path.join(request.allocator, &.{ request.directory, constants.library_file });

    defer request.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFileAtomic(request.io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(request.io);

    try compiler.library.codec.writeFile(request.io, file.file, request.backing, request.library);
    try file.replace(request.io);
}

pub fn writeStageAbi(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    write(self, constants.abi_file, self.abi.source) catch |err| return self.failure.save(err);
}

pub fn stageFileCount(handle: *const anyopaque, group: FileGroup) u64 {
    const self = State.get(handle);

    return switch (group) {
        .AbiViews => self.abi.views.len,
        .Generated => self.layout.generated.len,
        .Public => self.layout.public.len,
    };
}

pub fn writeStageFile(handle: *const anyopaque, group: FileGroup, index: u64) Error!void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const File = struct { path: []const u8, source: []const u8 };

    const file: File = switch (group) {
        .AbiViews => .{ .path = self.abi.views[row].path, .source = self.abi.views[row].source },
        .Generated => .{ .path = self.layout.generated[row].path, .source = self.request.bundle.modules[row].source },
        .Public => .{ .path = self.layout.public[row].path, .source = self.request.bundle.public_modules[row].file.source },
    };

    write(self, file.path, file.source) catch |err| return self.failure.save(err);
}

fn write(self: *State, path: []const u8, source: []const u8) !void {
    const request = self.request;
    const target = try std.fs.path.join(request.allocator, &.{ request.directory, path });

    defer request.allocator.free(target);

    try artifacts.write(request.io, target, source);
}

pub fn writeStageManifest(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    writeManifest(self) catch |err| return self.failure.save(err);
}

fn writeManifest(self: *State) !void {
    const request = self.request;
    const path = try std.fs.path.join(request.allocator, &.{ request.directory, constants.package_file });

    defer request.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFileAtomic(request.io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(request.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(request.io, &buffer);

    @import("../../../package/manifest/write.zig").write(&writer.interface, self.config) catch return writer.err.?;

    writer.interface.flush() catch return writer.err.?;

    try file.replace(request.io);
}

pub fn writeStageBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const allocator = self.request.allocator;
    const source = @import("../../library_config.zig").render(allocator, self.config, self.layout.public, self.layout.generated, self.abi.views) catch |err| return self.failure.save(err);

    defer allocator.free(source);
    write(self, constants.build_file, source) catch |err| return self.failure.save(err);
}

pub fn writeStageInventory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    writeInventory(self) catch |err| return self.failure.save(err);
}

fn writeInventory(self: *State) !void {
    const request = self.request;
    const path = try std.fs.path.join(request.allocator, &.{ request.directory, inventory.name });

    defer request.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFileAtomic(request.io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(request.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(request.io, &buffer);
    const resources = self.resources;

    std.json.Stringify.value(.{
        .format_version = constants.managed_inventory,
        .library = self.config.library,
        .ir_version = @import("zx").ir_version,
        .public_modules = self.layout.public,
        .store_initializers = request.bundle.store_initializers,
        .native_sources_bundled = resources.bundled_files.items.len != 0,
        .bundled_files = resources.bundled_files.items,
        .managed_files = self.managed,
        .native_dependencies = resources.dependencies,
        .generated_modules = self.layout.generated,
        .external_build_requirements = .{
            .libraries = self.config.libraries,
            .include_paths = resources.external_includes.items,
            .library_paths = self.config.library_paths,
        },
    }, .{ .whitespace = .indent_2 }, &writer.interface) catch return writer.err.?;

    if (writer.logicalPos() >= inventory.limit) return error.StreamTooLong;

    writer.interface.flush() catch return writer.err.?;

    try file.replace(request.io);
}
