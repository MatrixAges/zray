const std = @import("std");
const compiler = @import("compiler");
const Loaded = @import("../project.zig").Loaded;
const Config = @import("../project.zig").Config;
const Inputs = @import("watch_inputs").Inputs;
const artifacts = @import("../artifacts.zig");
const config_writer = @import("../library_config.zig");
const inventory = @import("publication_host").inventory;
const constants = @import("cli_source").library_publication_constants.@"zx.constants";

pub fn write(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, library: *const compiler.library.Result, bundle: compiler.zig.LibraryBundle, loaded: Loaded, inputs: ?*Inputs) ![]const inventory.File {
    const abi = try @import("../abi.zig").createLibrary(allocator, bundle, loaded);
    const resources = try @import("resources.zig").write(io, allocator, directory, loaded, inputs);
    const plan = try @import("publication/layout.zig").create(allocator, loaded.config, library, &bundle);

    const config: Config = .{
        .name = plan.name,
        .version = plan.version,
        .library = constants.library_file,
        .exports = plan.exports,
        .private = loaded.config.private,
        .native_modules = resources.native_modules,
        .libraries = loaded.config.libraries,
        .library_paths = resources.library_paths,
    };

    try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, constants.library_file }), try compiler.library.codec.encode(allocator, library));
    try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, constants.abi_file }), abi.source);
    for (abi.views) |view| try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, view.path }), view.source);

    for (bundle.modules, plan.generated) |module, output| {
        try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, output.path }), module.source);
    }

    for (bundle.public_modules, plan.public) |module, output| {
        try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, output.path }), module.file.source);
    }

    try writeManifest(io, try std.fs.path.join(allocator, &.{ directory, constants.package_file }), config);

    const build_source = try config_writer.render(allocator, config, plan.public, plan.generated, abi.views);

    defer allocator.free(build_source);

    try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, constants.build_file }), build_source);

    const managed = try inventory.collect(io, allocator, directory);

    try writeInventory(io, try std.fs.path.join(allocator, &.{ directory, inventory.name }), .{
        .format_version = constants.managed_inventory,
        .library = config.library,
        .ir_version = @import("zx").ir_version,
        .public_modules = plan.public,
        .store_initializers = bundle.store_initializers,
        .native_sources_bundled = resources.bundled_files.len != 0,
        .bundled_files = resources.bundled_files,
        .managed_files = managed,
        .native_dependencies = resources.dependencies,
        .generated_modules = plan.generated,
        .external_build_requirements = .{ .libraries = config.libraries, .include_paths = resources.external_includes, .library_paths = config.library_paths },
    });

    return managed;
}

fn writeManifest(io: std.Io, path: []const u8, config: Config) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(io, &buffer);

    @import("../../package/manifest/write.zig").write(&writer.interface, config) catch return writer.err.?;

    writer.interface.flush() catch return writer.err.?;

    try file.replace(io);
}

fn writeInventory(io: std.Io, path: []const u8, metadata: anytype) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.file.writerStreaming(io, &buffer);

    std.json.Stringify.value(metadata, .{ .whitespace = .indent_2 }, &writer.interface) catch return writer.err.?;

    if (writer.logicalPos() >= inventory.limit) return error.StreamTooLong;

    writer.interface.flush() catch return writer.err.?;

    try file.replace(io);
}
