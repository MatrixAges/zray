const std = @import("std");
const compiler = @import("compiler");
const inventory = @import("publication_host").inventory;
const constants = @import("cli_source").library_publication_constants.@"zx.constants";
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;

pub fn writeStageFile(handle: *const anyopaque, path: []const u8, source: []const u8) Error!void {
    const self = State.get(handle);

    self.disk.writeFile(path, source) catch |err| return self.failure.save(err);
}

pub fn writeStageArtifact(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    writeArtifact(self) catch |err| return self.failure.save(err);
}

fn writeArtifact(self: *State) !void {
    const request = self.request;
    var file = try self.disk.create(constants.library_file);

    defer file.deinit(request.io);

    try compiler.library.codec.writeFile(request.io, file.file, request.backing, request.library);
    try file.replace(request.io);
}

pub fn writeStageManifest(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    writeManifest(self) catch |err| return self.failure.save(err);
}

fn writeManifest(self: *State) !void {
    const request = self.request;
    var file = try self.disk.create(constants.package_file);

    defer file.deinit(request.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(request.io, &buffer);

    @import("../../../package/manifest/write.zig").write(request.backing, &writer.interface, self.config) catch |err| return switch (err) {
        error.WriteFailed => writer.err.?,
        else => err,
    };

    writer.interface.flush() catch return writer.err.?;

    try file.replace(request.io);
}

pub fn renderStageBuild(allocator: std.mem.Allocator, handle: *const anyopaque) Error![]const u8 {
    const self = State.get(handle);

    return @import("../../library_config.zig").render(allocator, self.config, self.layout.public, self.layout.generated, self.abi.views) catch |err| self.failure.save(err);
}

pub fn writeStageInventory(handle: *const anyopaque, external_includes: []const []const u8) Error!void {
    const self = State.get(handle);

    writeInventory(self, external_includes) catch |err| return self.failure.save(err);
}

fn writeInventory(self: *State, external_includes: []const []const u8) !void {
    const request = self.request;
    var file = try self.disk.create(inventory.name);

    defer file.deinit(request.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(request.io, &buffer);
    const resources = &self.resources;

    std.json.Stringify.value(.{
        .format_version = constants.managed_inventory,
        .library = self.config.library,
        .ir_version = @import("zx").ir_version,
        .public_modules = InventoryModules{ .rows = self.layout.public },
        .store_initializers = request.bundle.store_initializers,
        .native_sources_bundled = resources.bundled_files.items.len != 0,
        .bundled_files = resources.bundled_files.items,
        .managed_files = self.managed,
        .native_dependencies = resources.dependencies,
        .generated_modules = InventoryModules{ .rows = self.layout.generated },
        .external_build_requirements = .{
            .libraries = self.config.libraries,
            .include_paths = external_includes,
            .library_paths = self.config.library_paths,
        },
    }, .{ .whitespace = .indent_2 }, &writer.interface) catch return writer.err.?;

    if (writer.logicalPos() >= inventory.limit) return error.StreamTooLong;

    writer.interface.flush() catch return writer.err.?;

    try file.replace(request.io);
}

const InventoryModules = struct {
    rows: []const compiler.zig.host.library.Module,
    pub fn jsonStringify(self: InventoryModules, writer: anytype) !void {
        try writer.beginArray();

        for (self.rows) |row| {
            try writer.write(.{ .name = row.name, .path = row.path, .dependencies = row.dependencies });
        }

        try writer.endArray();
    }
};
