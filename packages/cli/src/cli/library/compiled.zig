const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const analysis = @import("analyze.zig");
const inventory = @import("publication_host").inventory;
const layout = @import("cli_source").library_legacy_output;
const selection = @import("cli_source").compiled_manifest_selection;
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

    var decoded = try @import("artifact.zig").open(options.backing, .{
        .io = options.io,
        .path = path,
        .scopes = project.package_scopes,
        .inputs = options.inputs,
    });

    defer decoded.deinit();

    const exports = try owned.alloc(compiler.library.PublicReference, config.exports.len);
    const names = zx.memory.borrowTextColumn("path", config.exports);
    const modules = zx.memory.borrowReadColumn(?[]const u8, "module", config.exports);
    var target_names = zx.memory.borrowWriteColumn([]const u8, "name", exports);
    var target_modules = zx.memory.borrowWriteColumn([]const u8, "module", exports);
    const Selection = std.meta.Child(selection.Input);
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const selected = zx.columns.invoke(selection.executeValue, fixed.allocator(), &Selection{
        .source = &.{ .count = exports.len, .names = @ptrCast(&names), .modules = @ptrCast(&modules) },
        .target = &.{ .names = @ptrCast(&target_names), .modules = @ptrCast(&target_modules) },
        .preserve_legacy = options.preserve_zig_entry,
    }) catch unreachable;

    if (!selected.valid) return error.InvalidCompiledExport;

    const legacy_single = selected.legacy and try legacySingle(owned, options);

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
    const path = try std.fs.path.resolve(allocator, &.{ options.loaded.project.root_dir, inventory.name });

    if (options.inputs) |inputs| try inputs.add(options.io, path);

    @import("../../package/source.zig").validateWithInputs(options.io, allocator, path, options.loaded.project.package_scopes, options.inputs) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(options.io, path, options.backing, .limited(inventory.limit)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    defer options.backing.free(bytes);

    if (options.inputs) |inputs| try inputs.record(options.io, path, bytes);

    const Metadata = struct { public_modules: []const struct { name: []const u8, path: []const u8 } = &.{} };
    var scratch = std.heap.ArenaAllocator.init(options.backing);

    defer scratch.deinit();

    const metadata = try std.json.parseFromSliceLeaky(Metadata, scratch.allocator(), bytes, .{ .ignore_unknown_fields = true });
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

    return zx.columns.invoke(layout.executeValue, fixed.allocator(), &input) catch unreachable;
}
