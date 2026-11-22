const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const Collector = @import("collect.zig");
const Frontier = @import("frontier.zig");
const model = @import("model.zig");
const rx_edges = @import("rx_edges.zig");
const zx_edges = @import("zx_edges.zig");
const enabled = @import("rx_options").generated_graph;

pub fn run(collector: *Collector, adjacency: *model.Adjacency, roots: []const u64, sources: []const project.Source, modules: []const rx.ModuleSource, stores: []const rx.ModuleSource, shared: ?*project.ParseCache, prefetched: ?*project.ParseCache.Prefetched) Collector.Error!usize {
    const backing = collector.backing;
    var local = project.ParseCache{ .allocator = collector.allocator };

    defer local.deinit();

    const cache = shared orelse &local;
    const paths = collector.modules.items(.path);
    var parsed = try cache.prefetchRegistered(backing, sources, paths[0..sources.len]);

    defer parsed.deinit(backing);

    var frontier = try Frontier.init(backing, collector.modules.len);

    defer frontier.deinit(backing);

    var scan: Scan = .{
        .collector = collector,
        .adjacency = adjacency,
        .roots = roots,
        .sources = sources,
        .modules = modules,
        .stores = stores,
        .parsed = &parsed,
        .frontier = &frontier,
    };

    defer cache.reused += scan.reused;

    if (comptime enabled) {
        const rule = @import("generated_rx_visit_source_graph");

        const input: std.meta.Child(rule.Input) = .{
            .target = @ptrCast(&scan),
            .zx_count = collector.sources.zx_count,
            .rx_end = collector.sources.rx_end,
            .end = collector.modules.len,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            error.InvalidGraph => return error.InvalidGraph,
            else => unreachable,
        };
    } else {
        var next = scan.first();

        while (next) |owner| {
            switch (collector.sources.at(owner)) {
                .zx => try scan.collectZX(owner),
                .rx => |row| try scan.collectRX(owner, modules[row]),
                .store => |row| try scan.collectRX(owner, stores[row]),
            }

            next = try scan.finish(owner);
        }
    }

    adjacency.targets = collector.targets.items;

    if (prefetched) |output| {
        output.* = parsed;
        parsed = .{};
    }

    return frontier.end;
}

const Scan = struct {
    collector: *Collector,
    adjacency: *model.Adjacency,
    roots: []const u64,
    sources: []const project.Source,
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource,
    parsed: *project.ParseCache.Prefetched,
    frontier: *Frontier,
    reused: usize = 0,
    fn borrow(handle: *const anyopaque) *Scan {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn first(self: *Scan) ?usize {
        return self.frontier.advance(self.adjacency, .{ .targets = self.roots, .end = 0 });
    }
    fn collectZX(self: *Scan, owner: usize) Collector.Error!void {
        const source = self.sources[owner];
        const parsed = self.parsed.module(owner);
        const collector = self.collector;

        collector.begin(owner, source.source);

        self.reused += 1;

        if (parsed.diagnostic()) |issue| {
            collector.issue = .{
                .path = collector.modules.items(.path)[owner],
                .location = rx.sourceLocation(source.source, issue.span.start),
                .code = @tagName(issue.code),
                .message = try collector.allocator.dupe(u8, issue.message),
            };

            return error.InvalidGraph;
        }

        switch (parsed.*) {
            .native => |result| try zx_edges.collect(collector, zx.syntax.header.Native{ .program = result.value.parsed.ast }),
            .indexed => |*result| if (project.ParseCache.indexed_enabled) {
                const header = result.header();

                if (comptime enabled) {
                    try @import("references/scan.zig").collectZx(collector, header);
                } else {
                    try zx_edges.collect(collector, header);
                }
            } else unreachable,
        }
    }

    fn collectRX(self: *Scan, owner: usize, module: rx.ModuleSource) Collector.Error!void {
        self.collector.begin(owner, "");

        if (comptime enabled) {
            if (module.indexedReferences()) |entries| {
                return @import("references/scan.zig").collectRx(self.collector, module.path, entries);
            }
        }

        try rx_edges.collect(self.collector, module);
    }
    fn finish(self: *Scan, owner: usize) Collector.Error!?usize {
        const collector = self.collector;

        collector.modules.items(.dependencies)[owner] = try collector.edges.toOwnedSlice(collector.allocator);

        const targets = collector.targets.items;
        const next = self.frontier.advance(self.adjacency, .{ .targets = targets[self.frontier.edge_end..], .end = targets.len });

        _ = collector.temporary.reset(.retain_capacity);

        return next;
    }
};

pub fn firstSourceGraphVisit(handle: *const anyopaque) u64 {
    const scan = Scan.borrow(handle);

    return scan.first() orelse scan.collector.modules.len;
}

pub fn readSourceGraphZX(handle: *const anyopaque, owner: u64) Collector.Error!void {
    try Scan.borrow(handle).collectZX(@intCast(owner));
}

pub fn readSourceGraphRX(handle: *const anyopaque, owner: u64, row: u64, store: bool) Collector.Error!void {
    const scan = Scan.borrow(handle);
    const index: usize = @intCast(row);

    try scan.collectRX(@intCast(owner), if (store) scan.stores[index] else scan.modules[index]);
}

pub fn finishSourceGraphVisit(handle: *const anyopaque, owner: u64) Collector.Error!u64 {
    const scan = Scan.borrow(handle);

    return (try scan.finish(@intCast(owner))) orelse scan.collector.modules.len;
}
