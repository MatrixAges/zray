const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const frontend = @import("frontend");
const model = @import("source_graph/model.zig");
const Collector = @import("source_graph/collect.zig");
pub const Result = model.Result;
pub const Graph = model.Graph;
pub const Reference = model.Reference;
pub const Signatures = @import("references/signatures.zig");
pub const references = @import("source_graph/rx_edges.zig");

pub const Options = struct {
    entry: []const u8,
    additional_roots: []const []const u8 = &.{},
    /// Add the registered RX modules before the explicit roots.
    include_rx_modules: bool = false,
    sources: []const frontend.project.Source,
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource = &.{},
    project: frontend.project.Options,
    parse_cache: ?*frontend.project.ParseCache = null,
    /// Optional output for the immediately following signature analysis. Requires a shared cache.
    prefetched: ?*frontend.project.ParseCache.Prefetched = null,
    scratch_allocator: ?std.mem.Allocator = null,
    /// Optional caller-owned index. Its buckets use the scratch allocator and its keys may borrow the result.
    registered_paths: ?*frontend.project.source_index.Map = null,
    retain_source_dependencies: bool = false,
};

pub fn build(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Result {
    return buildWithRoots(allocator, options, options.additional_roots);
}

/// Explicit roots may be path slices or the project's original export records.
pub fn buildWithRoots(allocator: std.mem.Allocator, options: Options, roots: anytype) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const value = try buildIn(arena.allocator(), options.scratch_allocator orelse allocator, options, roots);

    return .{ .arena = arena, .value = value };
}

fn buildIn(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: Options, explicit: anytype) std.mem.Allocator.Error!model.Value {
    std.debug.assert(options.prefetched == null or options.parse_cache != null);

    var storage: model.Modules = .empty;
    const sources: model.Sources = .{ .zx_count = options.sources.len, .rx_end = options.sources.len + options.modules.len };
    const count = sources.rx_end + options.stores.len;

    try storage.setCapacity(allocator, count);

    storage.len = count;

    var modules = storage.slice();
    var temporary = frontend.project.source_index.Map.empty;
    const paths = options.registered_paths orelse &temporary;
    const Index = frontend.project.source_index.Map;

    paths.* = if (comptime @hasDecl(Index, "borrowKeys"))
        try Index.borrowKeys(backing, modules.items(.path))

    else
        try Index.init(backing, modules.len);

    defer temporary.deinit(backing);

    if (try register(allocator, options, paths, &modules, sources)) |issue| return issue;

    const root_location: rx.ast.Location = .{ .offset = 0, .line = 1, .column = 1 };
    const path = try std.fs.path.resolve(backing, &.{ options.project.root_dir, options.entry });

    defer backing.free(path);

    const entry = paths.get(path) orelse return failure(allocator, path, root_location, "entry module is missing from the registered source set");
    const rx_roots = if (options.include_rx_modules) options.modules.len else 0;
    const explicit_count = explicit.len;
    const additional_count = rx_roots + explicit_count;
    const roots = try allocator.alloc(u64, additional_count + options.stores.len + 1);
    roots[0] = entry;

    writeRootRows(roots[1..][0..rx_roots], sources.zx_count);
    writeRootRows(roots[1 + additional_count ..], sources.rx_end);

    var path_buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&path_buffer, backing);
    const temporary_paths = scratch.allocator();

    for (explicit, roots[1 + rx_roots ..][0..explicit_count]) |item, *root| {
        const source_path = if (@TypeOf(item) == []const u8) item else item.path;
        const resolved = try std.fs.path.resolve(temporary_paths, &.{ options.project.root_dir, source_path });

        defer temporary_paths.free(resolved);

        root.* = paths.get(resolved) orelse return failure(allocator, resolved, root_location, "source graph root is missing from the registered input set");
    }

    const additional_roots = try nativeRows(allocator, roots[1..][0..additional_count]);
    const target_allocator = if (options.retain_source_dependencies) allocator else backing;
    const starts = try target_allocator.alloc(u64, modules.len + 1);

    defer if (!options.retain_source_dependencies) backing.free(starts);

    const ends = try target_allocator.alloc(u64, modules.len);

    defer if (!options.retain_source_dependencies) backing.free(ends);
    @memset(starts, 0);
    @memset(ends, 0);

    var adjacency: model.Adjacency = .{ .starts = starts, .ends = ends };

    var collector = Collector{
        .allocator = allocator,
        .backing = backing,
        .target_allocator = target_allocator,
        .temporary = .init(backing),
        .options = options.project,
        .modules = modules,
        .sources = sources,
        .paths = paths,
    };

    defer collector.temporary.deinit();
    defer if (!options.retain_source_dependencies) collector.targets.deinit(backing);

    if (collector.options.source_index == null) collector.options.source_index = paths;

    var prefetched: frontend.project.ParseCache.Prefetched = .{};

    defer prefetched.deinit(backing);

    const reached = @import("source_graph/scan.zig").run(&collector, &adjacency, roots, options.sources, options.modules, options.stores, options.parse_cache, if (options.prefetched != null) &prefetched else null) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = collector.issue.? };
    };

    return switch (try @import("source_graph/order.zig").build(allocator, backing, modules, sources, adjacency, roots, options.sources, reached)) {
        .schedule => |schedule| done: {
            if (options.prefetched) |output| {
                output.* = prefetched;
                prefetched = .{};
            }

            break :done .{ .graph = .{
                .modules = modules,
                .sources = sources,
                .order = schedule.order,
                .batch_ends = schedule.batch_ends,
                .entry = entry,
                .additional_roots = additional_roots,
                .source_dependencies = if (options.retain_source_dependencies) .{
                    .starts = starts,
                    .ends = ends,
                    .targets = adjacency.targets,
                } else null,
            } };
        },
        .diagnostic => |issue| .{ .diagnostic = issue },
    };
}

fn writeRootRows(target: []u64, first: usize) void {
    if (target.len == 0) return;

    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_source_graph_root_rows");
        const input: std.meta.Child(rule.Input) = .{ .roots = @ptrCast(&target), .first = first, .count = target.len };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return;
    }

    for (target, first..) |*row, index| row.* = index;
}

fn nativeRows(allocator: std.mem.Allocator, roots: []const u64) std.mem.Allocator.Error![]const usize {
    if (comptime @bitSizeOf(usize) == 64 and @alignOf(u64) >= @alignOf(usize)) return @ptrCast(roots);

    const result = try allocator.alloc(usize, roots.len);

    for (result, roots) |*row, root| row.* = @intCast(root);

    return result;
}

pub fn orderedRows(allocator: std.mem.Allocator, graph: *const Graph, kind: enum { zx, rx }) std.mem.Allocator.Error![]const u64 {
    const first = if (kind == .zx) 0 else graph.sources.zx_count;
    const end = if (kind == .zx) graph.sources.zx_count else graph.sources.rx_end;
    const entries = try allocator.alloc(u64, @min(end - first, graph.order.len));

    if (entries.len == 0) return entries;

    errdefer allocator.free(entries);

    if (comptime @import("rx_options").generated_graph and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64)) {
        const rule = @import("generated_source_graph_ordered_rows");

        const input: std.meta.Child(rule.Input) = .{
            .order = @ptrCast(graph.order),
            .first = first,
            .end = end,
            .entries = @ptrCast(&entries),
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const count = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return allocator.realloc(entries, @intCast(count));
    }

    var count: usize = 0;

    for (graph.order) |row| {
        if (row < first or row >= end) continue;

        entries[count] = row - first;
        count += 1;
    }

    return allocator.realloc(entries, count);
}

fn register(allocator: std.mem.Allocator, options: Options, paths: *frontend.project.source_index.Map, modules: *model.Modules.Slice, sources: model.Sources) std.mem.Allocator.Error!?model.Value {
    const staged = @hasDecl(frontend.project.source_index.Map, "firstDuplicate");
    const generated = @import("rx_options").generated_graph;

    const invalid = if (comptime staged and generated)
        try invalidRegistration(options, sources)
    else
        null;

    const end = invalid orelse modules.len;

    for (0..end) |index| {
        const source = sources.at(index);

        const rx_source = switch (source) {
            .zx => null,
            .rx => |row| options.modules[row],
            .store => |row| options.stores[row],
        };

        const source_path = if (rx_source) |item| item.path else options.sources[source.zx].path;

        if (comptime !(staged and generated)) if (rx_source) |item| {
            rx.validateSourcePath(allocator, source_path, if (source == .store) .store else .module) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                if (comptime staged) {
                    if (paths.firstDuplicate(index)) |row| return try duplicate(allocator, options, modules.items(.path)[row], sources.at(row));
                }

                return try failure(allocator, source_path, item.node.location, "RX source registration requires a project relative path of the expected module kind");
            };
        };

        const path = try std.fs.path.resolve(allocator, &.{ options.project.root_dir, source_path });

        modules.set(index, .{ .path = path });

        if (comptime !staged) {
            if (!paths.claim(index, path)) return try duplicate(allocator, options, path, source);
        }
    }

    if (comptime staged) {
        if (paths.firstDuplicate(end)) |row| return try duplicate(allocator, options, modules.items(.path)[row], sources.at(row));
    }

    if (invalid) |row| {
        const item = switch (sources.at(row)) {
            .zx => unreachable,
            .rx => |index| options.modules[index],
            .store => |index| options.stores[index],
        };

        return try failure(allocator, item.path, item.node.location, "RX source registration requires a project relative path of the expected module kind");
    }

    return null;
}

fn invalidRegistration(options: Options, sources: model.Sources) std.mem.Allocator.Error!?usize {
    if (options.modules.len == 0 and options.stores.len == 0) return null;

    const rule = @import("generated_source_graph_registration");
    const memory = @import("zx").memory;
    const modules = memory.borrowTextColumn("path", options.modules);
    const stores = memory.borrowTextColumn("path", options.stores);

    const input: std.meta.Child(rule.Input) = .{
        .modules = &.{ .items = @ptrCast(&modules), .length = modules.count },
        .stores = &.{ .items = @ptrCast(&stores), .length = stores.count },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const invalid = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return if (invalid) |row| sources.zx_count + @as(usize, @intCast(row)) else null;
}

fn duplicate(allocator: std.mem.Allocator, options: Options, path: []const u8, source: model.Source) std.mem.Allocator.Error!model.Value {
    const message = "source paths must be unique after normalization across RX, ZX and Store definitions";

    return switch (source) {
        .zx => failure(allocator, path, .{ .offset = 0, .line = 1, .column = 1 }, message),
        .rx => |index| failure(allocator, path, options.modules[index].node.location, message),
        .store => |index| failure(allocator, options.stores[index].path, options.stores[index].node.location, "Store definition path is already registered"),
    };
}

fn failure(allocator: std.mem.Allocator, path: []const u8, location: rx.ast.Location, message: []const u8) std.mem.Allocator.Error!model.Value {
    return .{ .diagnostic = .{
        .path = try allocator.dupe(u8, path),
        .location = location,
        .code = "module",
        .message = message,
    } };
}
