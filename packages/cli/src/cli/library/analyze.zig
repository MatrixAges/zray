const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const store = @import("rx_analysis").store;
const Loaded = @import("../project.zig").Loaded;
const Inputs = @import("../watch/inputs.zig");

pub const Module = struct {
    name: []const u8,
    analysis: compiler.AnalysisResult,
    sources: []const compiler.project.Source,
    store_definitions: []const store.Definition = &.{},
};

pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    modules: []Module,
    parse_cache: ?*compiler.project.ParseCache = null,
    compiled: ?compiler.library.Result = null,
    legacy_single: bool = false,
    pub fn deinit(self: *Result) void {
        for (self.modules) |*module| module.analysis.deinit();
        if (self.compiled) |*library| library.deinit();
        if (self.parse_cache) |cache| cache.deinit();

        const allocator = self.arena.child_allocator;

        self.arena.deinit();
        allocator.destroy(self.arena);

        self.* = undefined;
    }

    pub fn link(self: *Result, allocator: std.mem.Allocator) !compiler.library.Result {
        if (self.compiled) |library| {
            self.compiled = null;

            return library;
        }

        var temporary = std.heap.ArenaAllocator.init(allocator);

        defer temporary.deinit();

        const scratch = temporary.allocator();
        const inputs = try scratch.alloc(compiler.library.Input, self.modules.len);

        for (self.modules, inputs) |*module, *input| {
            if (module.analysis.value != .ir) return error.InvalidAnalysis;

            const initializers = try store.collectInitializers(scratch, module.store_definitions, &module.analysis.value.ir, module.analysis.public_functions);

            input.* = .{ .name = module.name, .analysis = &module.analysis, .borrowed_initializers = initializers };
        }

        return compiler.library.link(allocator, inputs);
    }
};

pub const Options = struct {
    io: std.Io,
    backing: std.mem.Allocator,
    loaded: Loaded,
    writer: *std.Io.Writer,
    inputs: ?*Inputs = null,
    parse_cache: ?*compiler.project.ParseCache = null,
    preserve_zig_entry: bool = false,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !?Result {
    if (options.loaded.config.exports.len == 0) return error.MissingPublicModules;
    if (options.loaded.config.library != null) return try @import("compiled.zig").load(allocator, options);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);

    var transferred = false;
    var count: usize = 0;
    const owned = arena.allocator();
    var modules: []Module = &.{};
    var parse_cache: ?*compiler.project.ParseCache = null;

    defer if (!transferred) {
        for (modules[0..count]) |*module| module.analysis.deinit();
        if (parse_cache) |cache| cache.deinit();

        arena.deinit();
        allocator.destroy(arena);
    };

    modules = try owned.alloc(Module, options.loaded.config.exports.len);

    const cache = options.parse_cache orelse local: {
        const local = try owned.create(compiler.project.ParseCache);

        local.* = .{ .allocator = allocator, .keeps_replaced = true };
        parse_cache = local;

        break :local local;
    };

    var libraries = @import("inputs.zig"){ .allocator = owned };

    defer libraries.deinit();

    for (options.loaded.config.exports, modules) |exported, *module| {
        var project = options.loaded.project;

        project.entry = try std.fs.path.resolve(owned, &.{ project.root_dir, exported.source });

        if (std.mem.endsWith(u8, project.entry, ".rx")) {
            const prepared = try @import("../rx/analyze.zig").run(owned, .{ .io = options.io, .project = project, .writer = options.writer, .parse_cache = cache, .inputs = options.inputs, .exports = &.{.{ .name = exported.path, .path = project.entry }} }) orelse return null;
            module.* = .{ .name = exported.path, .analysis = prepared.analysis, .sources = prepared.sources, .store_definitions = prepared.store_definitions };
        } else {
            const source = try std.Io.Dir.cwd().readFileAlloc(options.io, project.entry, owned, .limited(16 * 1024 * 1024));
            const detected = try @import("../sources.zig").readDetectingRx(options.io, owned, source, project, cache, options.inputs, &libraries);
            project.compiled_libraries = libraries.libraries.items;

            if (detected.has_rx) {
                const prepared = try @import("../rx/analyze.zig").run(owned, .{ .io = options.io, .project = project, .writer = options.writer, .parse_cache = cache, .inputs = options.inputs, .exports = &.{.{ .name = exported.path, .path = project.entry }} }) orelse return null;
                module.* = .{ .name = exported.path, .analysis = prepared.analysis, .sources = prepared.sources, .store_definitions = prepared.store_definitions };
            } else {
                const analyzed = try compiler.analyzeProjectWithCache(owned, detected.sources, project, cache);

                module.* = .{ .name = exported.path, .analysis = analyzed, .sources = detected.sources };
            }
        }

        count += 1;
        module.name = try owned.dupe(u8, module.name);

        if (module.analysis.value == .diagnostic) {
            const issue = module.analysis.value.diagnostic;
            const source = module.sources[issue.source_index orelse 0];
            const location = zx.source.locate(source.original orelse source.source, issue.span.start);

            try options.writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ source.path, location.line, location.column, issue.code, issue.message });

            return null;
        }
    }

    transferred = true;

    return .{ .arena = arena, .modules = modules, .parse_cache = parse_cache };
}
