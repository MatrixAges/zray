const std = @import("std");
const compiler = @import("compiler");
const store = @import("rx_analysis").store;
const Loaded = @import("../project.zig").Loaded;
const Inputs = @import("watch_inputs").Inputs;
const memory = @import("zx").memory;
const workflow = @import("cli_source").library_analyze;
const State = @import("analysis/rows.zig").State;
const linking = @import("link/inputs.zig");

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
        return linking.run(self, allocator);
    }

    pub fn collectSources(self: *const Result, allocator: std.mem.Allocator) !std.ArrayList(compiler.project.Source) {
        return linking.sources(self.modules, allocator);
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
    var analysis: State = .{ .allocator = allocator, .options = &options };
    const reference = &analysis;
    const exports = options.loaded.config.exports;
    const names = memory.borrowTextColumn("path", exports);
    const sources = memory.borrowTextColumn("source", exports);
    var invocation = std.heap.ArenaAllocator.init(options.backing);

    defer invocation.deinit();
    defer analysis.deinit();

    const outcome = workflow.executeIn(invocation.allocator(), &.{
        .analysis = @ptrCast(&reference),
        .export_count = exports.len,
        .exports = &.{
            .root = options.loaded.project.root_dir,
            .names = @ptrCast(&names),
            .sources = @ptrCast(&sources),
        },
        .compiled = options.loaded.config.library != null,
    }) catch |err| return analysis.failure.unwrap(err);

    return switch (outcome) {
        .Ready => analysis.take(),
        .Invalid => null,
        .MissingExports => error.MissingPublicModules,
    };
}
