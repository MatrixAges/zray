const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const model = @import("model.zig");
const Collector = @import("collect.zig");
const Scan = @import("scan.zig").Scan;
const Index = project.source_index.Map;
const native_width = @bitSizeOf(usize) == 64 and @alignOf(u64) >= @alignOf(usize);
const Allocator = std.mem.Allocator;
const Error = Collector.Error;
const root_location: rx.ast.Location = .{ .offset = 0, .line = 1, .column = 1 };

pub fn build(allocator: Allocator, backing: Allocator, opts: model.Options, explicit: anytype) Allocator.Error!model.Value {
    std.debug.assert(opts.prefetched == null or opts.parse_cache != null);

    const sources: model.Sources = .{ .zx_count = opts.sources.len, .rx_end = opts.sources.len + opts.modules.len };
    var storage: model.Modules = .empty;

    try storage.setCapacity(allocator, sources.rx_end + opts.stores.len);

    storage.len = sources.rx_end + opts.stores.len;

    const modules = storage.slice();
    var temporary = Index.empty;
    const paths = opts.registered_paths orelse &temporary;

    paths.* = if (comptime @hasDecl(Index, "borrowKeys"))
        try Index.borrowKeys(backing, modules.items(.path))

    else
        try Index.init(backing, modules.len);

    defer temporary.deinit(backing);

    const edge_allocator = if (opts.retain_source_dependencies) allocator else backing;

    var collector: Collector = .{
        .allocator = allocator,
        .backing = backing,
        .target_allocator = edge_allocator,
        .temporary = .init(backing),
        .options = opts.project,
        .modules = modules,
        .sources = sources,
        .paths = paths,
    };

    defer collector.temporary.deinit();

    if (collector.options.source_index == null) collector.options.source_index = paths;

    var local_cache: project.ParseCache = .{ .allocator = allocator };

    var scanner: Scan = .{
        .collector = &collector,
        .sources = opts.sources,
        .modules = opts.modules,
        .stores = opts.stores,
        .cache = opts.parse_cache orelse &local_cache,
        .owns_cache = opts.parse_cache == null,
    };

    defer scanner.deinit();

    var temporary_storage = std.heap.ArenaAllocator.init(backing);

    defer temporary_storage.deinit();

    var state: Build = .{
        .allocator = allocator,
        .scratch = temporary_storage.allocator(),
        .opts = &opts,
        .paths = paths,
        .scanner = &scanner,
        .modules = modules,
        .sources = sources,
    };

    defer state.deinit();

    const result = if (comptime @import("rx_options").generated_graph)
        state.generate(explicit)

    else
        state.seed(explicit);

    return result catch |err| switch (err) {
        error.InvalidGraph => .{ .diagnostic = state.diagnostic orelse collector.issue.? },
        error.OutOfMemory => error.OutOfMemory,
    };
}

const Build = struct {
    allocator: Allocator,
    scratch: Allocator,
    opts: *const model.Options,
    paths: *Index,
    scanner: *Scan,
    modules: model.Modules.Slice,
    sources: model.Sources,
    roots: []u64 = &.{},
    adjacency: model.Adjacency = .{ .starts = &.{}, .ends = &.{} },
    diagnostic: ?@FieldType(model.Value, "diagnostic") = null,
    fn borrow(handle: *anyopaque) *Build {
        return @ptrCast(@alignCast(handle));
    }
    fn deinit(self: *Build) void {
        if (self.opts.retain_source_dependencies) return;

        const collector = self.scanner.collector;
        const allocator = collector.target_allocator;

        collector.targets.deinit(allocator);
        allocator.free(self.adjacency.ends);
        allocator.free(self.adjacency.starts);
    }

    fn generate(self: *Build, explicit: anytype) Error!model.Value {
        const rule = @import("generated_rx_construct_source_graph");
        const memory = zx.memory;
        const opts = self.opts;
        const Element = std.meta.Elem(@TypeOf(explicit));
        const entries: []const Element = explicit[0..];
        const roots = if (Element == []const u8) memory.borrowTextSlice(entries) else memory.borrowTextColumn("path", entries);
        const zx_paths = memory.borrowTextColumn("path", opts.sources);
        const rx_paths = memory.borrowTextColumn("path", opts.modules);
        const stores = memory.borrowTextColumn("path", opts.stores);
        const frontier_allocator = self.scanner.collector.backing;
        var queue: []u64 = &.{};
        var seen: []u32 = &.{};

        defer {
            frontier_allocator.free(queue);
            frontier_allocator.free(seen);
        }

        @memset(self.modules.items(.dependencies), &.{});
        @memset(self.modules.items(.compiled_dependency), false);

        const input: std.meta.Child(rule.Input) = .{
            .target = @ptrCast(self),
            .root = opts.project.root_dir,
            .index = &.{ .keys = self.paths.keys, .buckets = @ptrCast(&self.paths.buckets), .capacity = self.paths.buckets.len },
            .paths = &.{ .zx = @ptrCast(&zx_paths), .rx = @ptrCast(&rx_paths), .stores = @ptrCast(&stores) },
            .normalized = @ptrCast(self.paths.keys.ptr),
            .path_allocator = @ptrCast(&self.allocator),
            .ranges = &.{
                .zx_count = self.sources.zx_count,
                .rx_end = self.sources.rx_end,
                .end = self.modules.len,
            },
            .explicit = @ptrCast(&roots),
            .explicit_count = entries.len,
            .entry = opts.entry,
            .roots = @ptrCast(&self.roots),
            .allocator = @ptrCast(&self.allocator),
            .temporary = @ptrCast(&self.scratch),
            .include_rx = opts.include_rx_modules,
            .visit = @ptrCast(self.scanner),
            .columns = &.{
                .seen = @ptrCast(&seen),
                .queue = @ptrCast(&queue),
                .starts = @ptrCast(&self.adjacency.starts),
                .ends = @ptrCast(&self.adjacency.ends),
            },
            .edge_allocator = @ptrCast(&self.scanner.collector.target_allocator),
            .frontier_allocator = @ptrCast(&frontier_allocator),
            .retain_parses = opts.prefetched != null,
            .retain_dependencies = opts.retain_source_dependencies,
        };

        const result = rule.executeIn(self.scratch, &input) catch |err| {
            return switch (@as(anyerror, err)) {
                error.InvalidGraph => error.InvalidGraph,
                error.OutOfMemory, error.Overflow => error.OutOfMemory,
                else => unreachable,
            };
        };

        std.debug.assert(result.count == result.order.len);

        const schedule: model.Schedule = .{
            .order = try self.indices(result.order, true),
            .batch_ends = try self.indices(result.batch_ends, true),
        };

        const dependencies: ?model.SourceDependencies = if (result.dependencies) |value|
            .{ .starts = value.starts, .ends = value.ends, .targets = value.targets }

        else
            null;

        return self.finish(@intCast(result.entry), @intCast(result.additional), schedule, dependencies, result.retain_parses);
    }
    fn indices(self: *Build, values: []const u64, comptime copy: bool) Allocator.Error![]const usize {
        if (native_width) return if (copy) self.allocator.dupe(usize, @ptrCast(values)) else @as([]const usize, @ptrCast(values));

        const result = try self.allocator.alloc(usize, values.len);

        for (result, values) |*row, value| row.* = @intCast(value);

        return result;
    }
    fn finish(self: *Build, entry: usize, additional: usize, schedule: model.Schedule, dependencies: ?model.SourceDependencies, retain_parses: bool) Allocator.Error!model.Value {
        const additional_roots = try self.indices(self.roots[1..][0..additional], false);

        if (retain_parses) {
            self.opts.prefetched.?.* = self.scanner.parsed;
            self.scanner.parsed = .{};
        }

        return .{ .graph = .{
            .modules = self.modules,
            .sources = self.sources,
            .order = schedule.order,
            .batch_ends = schedule.batch_ends,
            .entry = entry,
            .additional_roots = additional_roots,
            .source_dependencies = dependencies,
        } };
    }
    fn rxSource(self: *const Build, row: usize) ?rx.ModuleSource {
        return switch (self.sources.at(row)) {
            .zx => null,
            .rx => |index| self.opts.modules[index],
            .store => |index| self.opts.stores[index],
        };
    }
    fn path(self: *const Build, row: usize) []const u8 {
        return if (self.rxSource(row)) |source| source.path else self.opts.sources[row].path;
    }
    fn claim(self: *Build, row: usize, raw: []const u8) Allocator.Error!bool {
        const resolved = try std.fs.path.resolve(self.allocator, &.{ self.opts.project.root_dir, raw });

        self.modules.set(row, .{ .path = resolved });

        return self.paths.claim(row, resolved);
    }
    fn reject(self: *Build, path_name: []const u8, location: rx.ast.Location, message: []const u8) Error {
        self.diagnostic = .{
            .path = try self.allocator.dupe(u8, path_name),
            .location = location,
            .code = "module",
            .message = message,
        };

        return error.InvalidGraph;
    }
    fn rejectRegistration(self: *Build, row: usize, normalized: bool, message: []const u8) Error {
        return self.reject(
            if (normalized) self.modules.items(.path)[row] else self.path(row),
            if (self.rxSource(row)) |source| source.node.location else root_location,
            message,
        );
    }
    fn resolve(self: *Build, allocator: Allocator, raw: []const u8, message: []const u8) Error!usize {
        const resolved = try std.fs.path.resolve(allocator, &.{ self.opts.project.root_dir, raw });

        defer allocator.free(resolved);

        return self.paths.get(resolved) orelse self.reject(resolved, root_location, message);
    }
    fn seed(self: *Build, explicit: anytype) Error!model.Value {
        for (0..self.modules.len) |row| {
            const source_path = self.path(row);
            const store = self.sources.at(row) == .store;

            if (self.rxSource(row) != null) {
                rx.validateSourcePath(self.allocator, source_path, if (store) .store else .module) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return self.rejectRegistration(row, false, "RX source registration requires a project relative path of the expected module kind");
                };
            }

            if (!try self.claim(row, source_path)) {
                return self.rejectRegistration(row, !store, if (store)
                    "Store definition path is already registered"
                else
                    "source paths must be unique after normalization across RX, ZX and Store definitions");
            }
        }

        const entry = try self.resolve(self.scanner.collector.backing, self.opts.entry, "entry module is missing from the registered source set");
        const rx_roots = if (self.opts.include_rx_modules) self.opts.modules.len else 0;
        const additional_count = rx_roots + explicit.len;
        self.roots = try self.allocator.alloc(u64, 1 + additional_count + self.opts.stores.len);
        self.roots[0] = entry;

        for (self.roots[1..][0..rx_roots], self.sources.zx_count..) |*row, index| row.* = index;
        for (self.roots[1 + additional_count ..], self.sources.rx_end..) |*row, index| row.* = index;

        for (explicit, self.roots[1 + rx_roots ..][0..explicit.len]) |item, *root| {
            const source_path = if (@TypeOf(item) == []const u8) item else item.path;

            root.* = try self.resolve(self.scratch, source_path, "source graph root is missing from the registered input set");
        }

        const edge_allocator = self.scanner.collector.target_allocator;
        self.adjacency.starts = try edge_allocator.alloc(u64, self.modules.len + 1);
        self.adjacency.ends = try edge_allocator.alloc(u64, self.modules.len);

        @memset(self.adjacency.starts, 0);
        @memset(self.adjacency.ends, 0);

        try self.scanner.runSeed(&self.adjacency, self.roots, self.opts.prefetched != null);

        const schedule = switch (try @import("seed.zig").build(self.allocator, self.scanner.collector.backing, self.modules, self.sources, self.roots, self.opts.sources)) {
            .schedule => |value| value,
            .diagnostic => |value| {
                self.diagnostic = value;

                return error.InvalidGraph;
            },
        };

        const dependencies: ?model.SourceDependencies = if (self.opts.retain_source_dependencies) .{
            .starts = self.adjacency.starts,
            .ends = self.adjacency.ends,
            .targets = self.adjacency.targets,
        } else null;

        return self.finish(entry, additional_count, schedule, dependencies, self.opts.prefetched != null);
    }
};

pub fn rejectSourceGraphPath(handle: *anyopaque, row: u64, normalized: bool, message: []const u8) Error!void {
    return Build.borrow(handle).rejectRegistration(@intCast(row), normalized, message);
}

pub fn rejectSourceGraphRoot(handle: *anyopaque, path: []const u8, missing: []const u8) Error!u64 {
    return Build.borrow(handle).reject(path, root_location, missing);
}

pub fn rejectSourceGraphCycle(handle: *anyopaque, owner: u64, edge: u64) error{InvalidGraph}!void {
    const state = Build.borrow(handle);
    const row: usize = @intCast(owner);
    const module = state.modules.get(row);
    var source_index = state.adjacency.starts[row];

    for (module.dependencies) |dependency| {
        if (dependency.target != .source) continue;

        if (source_index == edge) {
            state.diagnostic = model.cycle(module, state.sources.at(row), dependency, state.opts.sources).diagnostic;

            return error.InvalidGraph;
        }

        source_index += 1;
    }

    unreachable;
}
