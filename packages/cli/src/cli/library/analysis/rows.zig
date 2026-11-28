const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const Export = @import("../../../package/manifest/model.zig").Export;
const Text = @import("../../sources/text.zig");
const Libraries = @import("../inputs.zig");
const analysis = @import("../analyze.zig");
const effects = @import("../workflow/effects.zig");
const Error = effects.Error;

pub const State = struct {
    allocator: std.mem.Allocator,
    options: *const analysis.Options,
    failure: effects.Failure = .{},
    result: ?analysis.Result = null,
    count: usize = 0,
    cache: *compiler.project.ParseCache = undefined,
    libraries: ?Libraries = null,
    texts: ?Text.Cache = null,
    active: ?compiler.project.Options = null,
    detected: []const compiler.project.Source = &.{},
    pub fn deinit(self: *State) void {
        if (self.texts) |*texts| texts.deinit();
        if (self.libraries) |*libraries| libraries.deinit();

        if (self.result) |*result| {
            result.modules = result.modules[0..self.count];

            result.deinit();
        }
    }

    pub fn take(self: *State) analysis.Result {
        const result = self.result.?;
        self.result = null;

        return result;
    }
    fn memory(self: *State) std.mem.Allocator {
        return self.result.?.arena.allocator();
    }

    fn module(self: *State) *analysis.Module {
        return &self.result.?.modules[self.count];
    }

    fn exports(self: *const State) []const Export {
        return self.options.loaded.config.exports;
    }
};

pub fn loadCompiledLibrary(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    self.result = @import("../compiled.zig").load(self.allocator, self.options.*) catch |err| return self.failure.save(err);
}

pub fn beginLibraryAnalysis(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const allocator = self.allocator;
    const arena = allocator.create(std.heap.ArenaAllocator) catch |err| return self.failure.save(err);
    arena.* = .init(allocator);
    self.result = .{ .arena = arena, .modules = &.{} };

    const owned = arena.allocator();

    self.result.?.modules = owned.alloc(analysis.Module, self.exports().len) catch |err| return self.failure.save(err);

    self.cache = self.options.parse_cache orelse local: {
        const cache = owned.create(compiler.project.ParseCache) catch |err| return self.failure.save(err);
        cache.* = .{ .allocator = allocator, .keeps_replaced = true };
        self.result.?.parse_cache = cache;

        break :local cache;
    };

    self.libraries = .{ .allocator = owned };
    self.texts = .{ .allocator = owned };
}

pub fn readLibraryDependencies(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = effects.state(State, handle);
    var project = self.options.loaded.project;
    project.entry = self.memory().dupe(u8, path) catch |err| return self.failure.save(err);

    const options = self.options;
    const stored = @import("../../sources.zig").readLibrary(options.io, self.memory(), project, self.cache, options.inputs, &self.libraries.?, &self.texts.?) catch |err| return self.failure.save(err);

    project.compiled_libraries = self.libraries.?.libraries.items;
    self.active = project;
    self.detected = stored.sources;

    return stored.has_rx;
}

pub fn inferLibraryRx(handle: *const anyopaque, name: []const u8, path: []const u8) Error!bool {
    const self = effects.state(State, handle);
    const options = self.options;
    const module = self.module();

    const project = self.active orelse direct: {
        var direct = options.loaded.project;

        direct.entry = self.memory().dupe(u8, path) catch |err| return self.failure.save(err);

        break :direct direct;
    };

    self.active = null;

    const prepared = (@import("../../rx/analyze.zig").run(self.memory(), .{
        .io = options.io,
        .project = project,
        .writer = options.writer,
        .parse_cache = self.cache,
        .inputs = options.inputs,
        .exports = &.{.{ .name = name, .path = project.entry }},
        .texts = &self.texts.?,
    }) catch |err| return self.failure.save(err)) orelse return false;

    module.name = name;
    module.analysis = prepared.analysis;
    module.sources = prepared.sources;
    module.store_definitions = prepared.store_definitions;

    return true;
}

pub fn inferLibraryZx(handle: *const anyopaque, name: []const u8) Error!void {
    const self = effects.state(State, handle);
    const module = self.module();

    module.name = name;
    module.analysis = compiler.analyzeProjectWithCache(self.memory(), self.detected, self.active.?, self.cache) catch |err| return self.failure.save(err);
    self.active = null;
    module.sources = self.detected;
    module.store_definitions = &.{};
}

pub fn recordLibraryAnalysis(handle: *const anyopaque) Error!bool {
    const self = effects.state(State, handle);
    const module = self.module();

    self.count += 1;
    module.name = self.memory().dupe(u8, module.name) catch |err| return self.failure.save(err);

    if (module.analysis.value != .diagnostic) return true;

    const issue = module.analysis.value.diagnostic;
    const source = module.sources[issue.source_index orelse 0];
    const location = zx.source.locate(source.original orelse source.source, issue.span.start);

    self.options.writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ source.path, location.line, location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return false;
}
