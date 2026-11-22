const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const model = @import("model.zig");
const Collector = @import("collect.zig");
const Index = project.source_index.Map;
const Prefetched = project.ParseCache.Prefetched;
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

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, backing);

    var state: Build = .{
        .allocator = allocator,
        .backing = backing,
        .scratch = scratch.allocator(),
        .opts = &opts,
        .paths = paths,
        .modules = modules,
        .sources = sources,
    };

    defer state.deinit();

    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_construct_source_graph");
        const memory = zx.memory;
        const Element = std.meta.Elem(@TypeOf(explicit));
        const entries: []const Element = explicit[0..];
        const roots = if (Element == []const u8) memory.borrowTextSlice(entries) else memory.borrowTextColumn("path", entries);

        const input: std.meta.Child(rule.Input) = .{
            .target = @ptrCast(&state),
            .ranges = &.{
                .zx_count = sources.zx_count,
                .rx_end = sources.rx_end,
                .end = modules.len,
            },
            .explicit = @ptrCast(&roots),
            .explicit_count = entries.len,
            .include_rx = opts.include_rx_modules,
            .retain_parses = opts.prefetched != null,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(rule.executeIn, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.InvalidGraph => return state.value,
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };
    } else {
        state.seed(explicit) catch |err| switch (err) {
            error.InvalidGraph => return state.value,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    return state.value;
}

const Build = struct {
    allocator: Allocator,
    backing: Allocator,
    scratch: Allocator,
    opts: *const model.Options,
    paths: *Index,
    modules: model.Modules.Slice,
    sources: model.Sources,
    roots: []u64 = &.{},
    additional_roots: []const usize = &.{},
    entry: usize = 0,
    adjacency: model.Adjacency = .{ .starts = &.{}, .ends = &.{} },
    targets: std.ArrayList(u64) = .empty,
    prefetched: Prefetched = .{},
    schedule: model.Schedule = undefined,
    value: model.Value = undefined,
    fn borrow(handle: *const anyopaque) *Build {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn deinit(self: *Build) void {
        self.prefetched.deinit(self.backing);

        if (self.opts.retain_source_dependencies) return;

        self.targets.deinit(self.backing);
        self.backing.free(self.adjacency.ends);
        self.backing.free(self.adjacency.starts);
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
        self.value = .{ .diagnostic = .{
            .path = try self.allocator.dupe(u8, path_name),
            .location = location,
            .code = "module",
            .message = message,
        } };

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
    fn rootRange(self: *Build, start: usize, first: usize, count: usize) void {
        if (count == 0) return;

        const target = self.roots[start..][0..count];

        if (comptime @import("rx_options").generated_graph) {
            const rule = @import("generated_source_graph_root_rows");
            const input: std.meta.Child(rule.Input) = .{ .roots = @ptrCast(&target), .first = first, .count = count };
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        }

        for (target, first..) |*row, index| row.* = index;
    }
    fn finishRoots(self: *Build, additional_count: usize) Allocator.Error!void {
        const roots = self.roots[1..][0..additional_count];

        if (comptime @bitSizeOf(usize) == 64 and @alignOf(u64) >= @alignOf(usize)) {
            self.additional_roots = @ptrCast(roots);

            return;
        }

        const result = try self.allocator.alloc(usize, roots.len);

        for (result, roots) |*row, root| row.* = @intCast(root);

        self.additional_roots = result;
    }

    fn scan(self: *Build) Error!usize {
        const allocator = if (self.opts.retain_source_dependencies) self.allocator else self.backing;

        self.adjacency.starts = try allocator.alloc(u64, self.modules.len + 1);
        self.adjacency.ends = try allocator.alloc(u64, self.modules.len);

        @memset(self.adjacency.starts, 0);
        @memset(self.adjacency.ends, 0);

        var collector: Collector = .{
            .allocator = self.allocator,
            .backing = self.backing,
            .target_allocator = allocator,
            .temporary = .init(self.backing),
            .options = self.opts.project,
            .modules = self.modules,
            .sources = self.sources,
            .paths = self.paths,
        };

        defer collector.temporary.deinit();

        defer self.targets = collector.targets;

        if (collector.options.source_index == null) collector.options.source_index = self.paths;

        return @import("scan.zig").run(
            &collector,
            &self.adjacency,
            self.roots,
            self.opts.sources,
            self.opts.modules,
            self.opts.stores,
            self.opts.parse_cache,
            if (self.opts.prefetched != null) &self.prefetched else null,
        ) catch |err| {
            if (err == error.InvalidGraph) self.value = .{ .diagnostic = collector.issue.? };

            return err;
        };
    }

    fn order(self: *Build, reached: usize) Error!void {
        switch (try @import("order.zig").build(
            self.allocator,
            self.backing,
            self.modules,
            self.sources,
            self.adjacency,
            self.roots,
            self.opts.sources,
            reached,
        )) {
            .schedule => |schedule| self.schedule = schedule,
            .diagnostic => |diagnostic| {
                self.value = .{ .diagnostic = diagnostic };

                return error.InvalidGraph;
            },
        }
    }

    fn publishParses(self: *Build) void {
        self.opts.prefetched.?.* = self.prefetched;
        self.prefetched = .{};
    }

    fn publish(self: *Build) void {
        self.value = .{ .graph = .{
            .modules = self.modules,
            .sources = self.sources,
            .order = self.schedule.order,
            .batch_ends = self.schedule.batch_ends,
            .entry = self.entry,
            .additional_roots = self.additional_roots,
            .source_dependencies = if (self.opts.retain_source_dependencies) .{
                .starts = self.adjacency.starts,
                .ends = self.adjacency.ends,
                .targets = self.adjacency.targets,
            } else null,
        } };
    }
    fn seed(self: *Build, explicit: anytype) Error!void {
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

        self.entry = try self.resolve(self.backing, self.opts.entry, "entry module is missing from the registered source set");

        const rx_roots = if (self.opts.include_rx_modules) self.opts.modules.len else 0;
        const additional_count = rx_roots + explicit.len;
        self.roots = try self.allocator.alloc(u64, 1 + additional_count + self.opts.stores.len);
        self.roots[0] = self.entry;

        self.rootRange(1, self.sources.zx_count, rx_roots);
        self.rootRange(1 + additional_count, self.sources.rx_end, self.opts.stores.len);

        for (explicit, self.roots[1 + rx_roots ..][0..explicit.len]) |item, *root| {
            const source_path = if (@TypeOf(item) == []const u8) item else item.path;

            root.* = try self.resolve(self.scratch, source_path, "source graph root is missing from the registered input set");
        }

        try self.finishRoots(additional_count);
        try self.order(try self.scan());
        if (self.opts.prefetched != null) self.publishParses();

        self.publish();
    }
};

pub fn sourceGraphPath(handle: *const anyopaque, row: u64) []const u8 {
    return Build.borrow(handle).path(@intCast(row));
}

pub fn claimSourceGraphPath(handle: *const anyopaque, row: u64, path: []const u8) Allocator.Error!bool {
    return Build.borrow(handle).claim(@intCast(row), path);
}

pub fn rejectSourceGraphPath(handle: *const anyopaque, row: u64, normalized: bool, message: []const u8) Error!void {
    return Build.borrow(handle).rejectRegistration(@intCast(row), normalized, message);
}

pub fn resolveSourceGraphEntry(handle: *const anyopaque, message: []const u8) Error!u64 {
    const state = Build.borrow(handle);
    const entry = try state.resolve(state.backing, state.opts.entry, message);

    state.entry = entry;

    return entry;
}

pub fn allocateSourceGraphRoots(handle: *const anyopaque, count: u64, entry: u64) Allocator.Error!void {
    const state = Build.borrow(handle);
    state.roots = try state.allocator.alloc(u64, @intCast(count));
    state.roots[0] = entry;
}

pub fn writeSourceGraphRootRange(handle: *const anyopaque, start: u64, first: u64, count: u64) void {
    Build.borrow(handle).rootRange(@intCast(start), @intCast(first), @intCast(count));
}

pub fn writeSourceGraphRoot(handle: *const anyopaque, row: u64, raw: []const u8, missing: []const u8) Error!void {
    const state = Build.borrow(handle);

    state.roots[@intCast(row)] = try state.resolve(state.scratch, raw, missing);
}

pub fn finishSourceGraphRoots(handle: *const anyopaque, count: u64) Allocator.Error!void {
    try Build.borrow(handle).finishRoots(@intCast(count));
}

pub fn scanSourceGraph(handle: *const anyopaque) Error!u64 {
    return try Build.borrow(handle).scan();
}

pub fn orderSourceGraph(handle: *const anyopaque, reached: u64) Error!void {
    try Build.borrow(handle).order(@intCast(reached));
}

pub fn publishSourceGraphParses(handle: *const anyopaque) void {
    Build.borrow(handle).publishParses();
}

pub fn publishSourceGraph(handle: *const anyopaque) void {
    Build.borrow(handle).publish();
}
