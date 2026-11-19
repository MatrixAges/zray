const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("analyze.zig");
const inventory = @import("inventory.zig");
const layout = @import("cli_source").library_legacy_output;
const Legacy = std.meta.Child(layout.Input);

pub fn load(allocator: std.mem.Allocator, options: analysis.Options) !analysis.Result {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);

    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const owned = arena.allocator();
    const project = options.loaded.project;
    const config = options.loaded.config;
    const path = try std.fs.path.resolve(owned, &.{ project.root_dir, config.library.? });

    if (options.inputs) |inputs| try inputs.add(options.io, path);
    try @import("../../package/source.zig").validateWithInputs(options.io, owned, path, project.package_scopes, options.inputs);

    var decoded = payload: {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(options.io, path, options.backing, .limited(64 * 1024 * 1024));

        defer options.backing.free(bytes);

        if (options.inputs) |inputs| try inputs.record(options.io, path, bytes);

        break :payload try compiler.library.codec.decode(options.backing, bytes);
    };

    defer decoded.deinit();

    const exports = try owned.alloc(compiler.library.PublicReference, config.exports.len);

    for (config.exports, exports) |source, *target| target.* = .{ .name = source.path, .module = source.module orelse return error.InvalidCompiledExport };

    const legacy_single = options.preserve_zig_entry and try legacySingle(owned, options);

    const library = try compiler.library.load(allocator, .{
        .instance = project.root_dir,
        .artifact = path,
        .program = decoded.program,
        .exports = decoded.exports,
        .nominal_types = decoded.nominal_types,
        .store_initializers = decoded.store_initializers,
    }, exports);

    return .{ .arena = arena, .modules = &.{}, .compiled = library, .legacy_single = legacy_single };
}

fn legacySingle(allocator: std.mem.Allocator, options: analysis.Options) !bool {
    const exports = options.loaded.config.exports;

    if (!legacy(.{
        .count = exports.len,
        .name = if (exports.len == 0) null else exports[0].module,
        .path = if (exports.len == 0) null else exports[0].path,
        .form = .Export,
    })) return false;

    const path = try std.fs.path.resolve(allocator, &.{ options.loaded.project.root_dir, inventory.name });

    if (options.inputs) |inputs| try inputs.add(options.io, path);

    @import("../../package/source.zig").validateWithInputs(options.io, allocator, path, options.loaded.project.package_scopes, options.inputs) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(options.io, path, allocator, .limited(inventory.limit)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    if (options.inputs) |inputs| try inputs.record(options.io, path, bytes);

    const Metadata = struct { public_modules: []const struct { name: []const u8, path: []const u8 } = &.{} };
    const metadata = try std.json.parseFromSliceLeaky(Metadata, allocator, bytes, .{ .ignore_unknown_fields = true });
    const modules = metadata.public_modules;

    return legacy(.{
        .count = modules.len,
        .name = if (modules.len == 0) null else modules[0].name,
        .path = if (modules.len == 0) null else modules[0].path,
        .form = .Facade,
    });
}

fn legacy(input: Legacy) bool {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return @import("zx").columns.invoke(layout.executeValue, fixed.allocator(), &input) catch unreachable;
}
