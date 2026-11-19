const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const collection = @import("collection.zig");
const Sources = @import("../sources.zig");
const Inputs = @import("../watch/inputs.zig");
const Text = @import("../sources/text.zig");
pub const Result = struct { analysis: compiler.AnalysisResult, sources: []const compiler.project.Source, store_definitions: []const analysis.store.Definition };

pub const Options = struct {
    io: std.Io,
    project: compiler.project.Options,
    writer: *std.Io.Writer,
    parse_cache: *compiler.project.ParseCache,
    inputs: ?*Inputs = null,
    exports: []const analysis.project.Export = &.{},
    texts: ?*Text.Cache = null,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !?Result {
    const io = options.io;
    var project = options.project;
    const root = try std.fs.path.resolve(allocator, &.{project.root_dir});
    const owner = try std.fs.path.relative(allocator, root, null, root, project.entry);

    if (collection.outside(owner)) return error.RxEntryOutsideProject;

    const cache = options.parse_cache;
    var libraries = @import("../library/inputs.zig"){ .allocator = allocator };

    defer libraries.deinit();

    var loaded = try collection.load(allocator, .{
        .io = io,
        .root = root,
        .entry = owner,
        .writer = options.writer,
        .inputs = options.inputs,
        .project = project,
        .parse_cache = cache,
        .libraries = &libraries,
        .retained_source_allocator = allocator,
        .texts = options.texts,
    }) orelse return null;

    defer loaded.deinit();

    const physical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);

    defer allocator.free(physical_root);

    for (loaded.data.modules) |module| {
        const path = try std.fs.path.resolve(allocator, &.{ root, module.path });

        defer allocator.free(path);

        try validatePath(allocator, options, physical_root, path);
    }

    const functions = try @import("type_sources.zig").collect(allocator, .{
        .io = io,
        .project = project,
        .modules = loaded.data.modules,
        .stores = loaded.data.stores,
        .functions = loaded.data.functions,
        .writer = options.writer,
        .inputs = options.inputs,
        .texts = options.texts,
    }) orelse return null;

    var known: Sources.Known = .empty;
    const paths = try allocator.alloc([]const u8, functions.len);

    defer known.deinit(allocator);
    defer allocator.free(paths);

    for (functions, paths) |function, *path| {
        path.* = try std.fs.path.resolve(allocator, &.{ root, function.path });

        try known.put(allocator, path.*, function.source);
    }

    var traversal: Sources.Traversal = .{ .io = io, .allocator = allocator, .project = project, .cache = cache, .inputs = options.inputs, .libraries = &libraries, .known = &known, .texts = options.texts };

    defer traversal.deinit();

    for (functions, paths) |function, path| {
        if (traversal.paths.contains(path)) continue;
        try validatePath(allocator, options, physical_root, path);

        const first = traversal.sources.items.len;

        try traversal.readEntry(path, function.source, true);

        if (project.package_scopes.len == 0) {
            for (traversal.sources.items[first + 1 ..]) |item| {
                try validatePath(allocator, options, physical_root, item.path);
            }
        }
    }

    if (!try @import("compiled.zig").collect(allocator, .{ .io = io, .modules = loaded.data.modules, .project = project, .libraries = &libraries, .inputs = options.inputs, .writer = options.writer })) return null;

    project.compiled_libraries = libraries.libraries.items;

    var inferred = try analysis.project.infer(allocator, .{
        .entry = owner,
        .exports = options.exports,
        .modules = loaded.data.modules,
        .stores = loaded.data.stores,
        .sources = traversal.sources.items,
        .project = project,
        .parse_cache = cache,
        .scratch_allocator = std.heap.smp_allocator,
    });

    errdefer inferred.deinit();

    if (inferred.value == .diagnostic) {
        const issue = inferred.value.diagnostic;

        try options.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message });

        inferred.deinit();

        return null;
    }

    const contract = inferred.value.contract;

    for (loaded.data.sources) |source| {
        try traversal.sources.append(allocator, .{
            .path = try std.fs.path.resolve(allocator, &.{ root, source.path }),
            .source = source.source,
        });
    }

    return .{ .analysis = .{ .arena = inferred.arena, .value = .{ .ir = contract.program }, .nominal_types = contract.nominal_types, .store_initializers = contract.store_initializers, .entry_function = contract.entry_function, .public_functions = contract.public_functions }, .sources = try traversal.sources.toOwnedSlice(allocator), .store_definitions = contract.store_definitions };
}

fn validatePath(allocator: std.mem.Allocator, options: Options, root: []const u8, path: []const u8) !void {
    if (options.inputs) |inputs| try inputs.add(options.io, path);

    const real = try std.Io.Dir.cwd().realPathFileAlloc(options.io, path, allocator);

    defer allocator.free(real);

    const relative = try std.fs.path.relative(allocator, root, null, root, real);

    defer allocator.free(relative);

    if (collection.outside(relative)) return error.RxSourceOutsideProject;
    try @import("../../package/source.zig").validateWithInputs(options.io, allocator, path, options.project.package_scopes, options.inputs);
}
