const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const zx = @import("zx");
const rx = @import("rx");
const graph = analysis.project.source_graph;
const Collection = @import("collection.zig").Data;
const Libraries = @import("../library/inputs.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    collection: Collection,
    functions: []const rx.TextSource,
    project: compiler.project.Options,
    writer: *std.Io.Writer,
    cache: compiler.project.ParseCache,
    libraries: Libraries,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    imports: []const compiler.project.Source = &.{},
    paths: compiler.project.source_index.Map = .empty,
    prefetched: compiler.project.ParseCache.Prefetched = .{},
    graph_result: ?graph.Result = null,
    signatures: ?compiler.project.signature_project.Result = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.signatures) |*signatures| signatures.deinit();

        self.prefetched.deinit(self.allocator);

        if (self.graph_result) |*result| result.deinit();

        self.paths.deinit(self.allocator);
        self.allocator.free(self.imports);
        self.sources.deinit(self.allocator);
        self.seen.deinit(self.allocator);
        self.libraries.deinit();
        self.cache.deinit();
    }
};

pub fn validate(io: std.Io, allocator: std.mem.Allocator, collection: Collection, functions: []const rx.TextSource, project: compiler.project.Options, writer: *std.Io.Writer) !bool {
    if (collection.stores.len == 0) return true;

    var state: State = .{
        .io = io,
        .allocator = allocator,
        .collection = collection,
        .functions = functions,
        .project = project,
        .writer = writer,
        .cache = .{ .allocator = allocator },
        .libraries = .{ .allocator = allocator },
    };

    const reference = &state;

    defer state.deinit();

    return @import("cli_source").check_store_types.executeIn(allocator, @ptrCast(&reference)) catch |err| state.failure.unwrap(err);
}

pub fn storeCheckRootCount(handle: *const anyopaque) u64 {
    return State.get(handle).functions.len;
}

pub fn loadStoreCheckRoot(handle: *const anyopaque, index: u64) Error!u64 {
    const self = State.get(handle);
    const allocator = self.allocator;
    const function = self.functions[@intCast(index)];
    var options = self.project;

    options.entry = std.fs.path.resolve(allocator, &.{ options.root_dir, function.path }) catch |err| return self.failure.save(err);

    allocator.free(self.imports);

    self.imports = &.{};
    self.imports = @import("../sources.zig").readWithLibraries(self.io, allocator, function.source, options, &self.cache, null, &self.libraries) catch |err| return self.failure.save(err);

    return self.imports.len;
}

pub fn registerStoreCheckImport(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const source = self.imports[@intCast(index)];
    const allocator = self.allocator;
    const known = self.seen.getOrPut(allocator, source.path) catch |err| return self.failure.save(err);

    if (!known.found_existing) self.sources.append(allocator, source) catch |err| return self.failure.save(err);
}

pub fn buildStoreCheckGraph(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const collection = self.collection;

    self.project.compiled_libraries = self.libraries.libraries.items;

    self.graph_result = graph.build(self.allocator, .{
        .entry = collection.stores[0].path,
        .include_rx_modules = true,
        .modules = collection.modules,
        .stores = collection.stores,
        .sources = self.sources.items,
        .project = self.project,
        .parse_cache = &self.cache,
        .prefetched = &self.prefetched,
        .registered_paths = &self.paths,
    }) catch |err| return self.failure.save(err);

    const value = &self.graph_result.?.value;

    return if (value.* == .diagnostic) report(self.writer, value.diagnostic) catch |err| return self.failure.save(err) else true;
}

pub fn analyzeStoreCheckSignatures(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const allocator = self.allocator;
    const entries = graph.orderedRows(allocator, &self.graph_result.?.value.graph, .zx) catch |err| return self.failure.save(err);

    defer allocator.free(entries);

    self.signatures = compiler.project.analyzePrefetchedSignatures(allocator, self.prefetched, entries, self.project, &self.paths) catch |err| return self.failure.save(err);

    self.prefetched.deinit(allocator);

    const result = &self.signatures.?.value;

    if (result.* != .diagnostic) return true;

    const issue = result.diagnostic;
    const source = if (issue.source_index) |index| self.sources.items[index] else null;
    const location: zx.source.Location = if (source) |value| zx.source.locate(value.source, issue.span.start) else .{ .line = 1, .column = 1 };
    const path = if (source) |value| value.path else self.collection.stores[0].path;

    self.writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ path, location.line, location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return false;
}

pub fn checkStoreRegistry(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const signatures = &self.signatures.?.value.data;
    const closure = &self.graph_result.?.value.graph;
    var context = self.project.context;
    context.types = signatures.types;
    context.nominal_types = signatures.nominal_types;
    context.native_modules = signatures.native_modules;
    const indexed = graph.Signatures.init(self.allocator, closure.*, signatures.modules, &self.paths) catch |err| return self.failure.save(err);
    const edges = closure.modules.items(.dependencies)[closure.sources.rx_end..];
    const registry = analysis.store.registry.loadSignatures(self.allocator, self.collection.stores, context, edges, indexed) catch |err| return self.failure.save(err);

    return if (registry == .diagnostic) report(self.writer, registry.diagnostic) catch |err| return self.failure.save(err) else true;
}

fn report(writer: *std.Io.Writer, issue: anytype) !bool {
    try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message });

    return false;
}
