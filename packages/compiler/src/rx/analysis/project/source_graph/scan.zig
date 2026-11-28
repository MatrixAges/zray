const std = @import("std");
const rx = @import("rx");
const project = @import("frontend").project;
const Collector = @import("collect.zig");
const Frontier = @import("frontier.zig");
const model = @import("model.zig");
const rx_edges = @import("rx_edges.zig");
const zx_edges = @import("zx_edges.zig");

pub const Scan = struct {
    collector: *Collector,
    sources: []const project.Source,
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource,
    cache: ?*project.ParseCache,
    owns_cache: bool,
    parsed: project.ParseCache.Prefetched = .{},
    reused: usize = 0,
    fn borrow(handle: *anyopaque) *Scan {
        return @ptrCast(@alignCast(handle));
    }
    pub fn deinit(self: *Scan) void {
        self.finish(false);
    }
    pub fn open(self: *Scan, paths: []const []const u8, buckets: []const u64) std.mem.Allocator.Error!void {
        const registered = self.collector.paths;

        @memcpy(registered.keys, paths);
        @memcpy(registered.buckets, buckets);

        return self.prefetch();
    }
    fn prefetch(self: *Scan) std.mem.Allocator.Error!void {
        const paths = self.collector.modules.items(.path);
        self.parsed = try self.cache.?.prefetchRegistered(self.collector.backing, self.sources, paths[0..self.sources.len]);
    }
    pub fn finish(self: *Scan, retain_parses: bool) void {
        if (!retain_parses) self.parsed.deinit(self.collector.backing);

        const cache = self.cache orelse return;
        cache.reused += self.reused;

        if (self.owns_cache) cache.deinit();

        self.cache = null;
        _ = self.collector.temporary.reset(.free_all);
    }
    pub fn runSeed(self: *Scan, adjacency: *model.Adjacency, roots: []const u64, retain_parses: bool) Collector.Error!void {
        const collector = self.collector;

        try self.prefetch();

        var frontier = try Frontier.init(collector.backing, collector.modules.len);

        defer frontier.deinit(collector.backing);

        var next = frontier.advance(adjacency, .{ .targets = roots, .end = 0 });

        while (next) |owner| {
            switch (collector.sources.at(owner)) {
                .zx => try self.collectZX(owner),
                .rx => |row| try self.collectRX(owner, self.modules[row]),
                .store => |row| try self.collectRX(owner, self.stores[row]),
            }

            const targets = try self.publish(owner);

            next = frontier.advance(adjacency, .{ .targets = targets[frontier.edge_end..], .end = targets.len });
        }

        adjacency.targets = collector.targets.items;

        self.finish(retain_parses);
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

        try zx_edges.collect(collector, parsed);
    }
    fn collectRX(self: *Scan, owner: usize, module: rx.ModuleSource) Collector.Error!void {
        self.collector.begin(owner, "");
        try rx_edges.collect(self.collector, module);
    }
    fn publish(self: *Scan, owner: usize) std.mem.Allocator.Error![]const u64 {
        const collector = self.collector;

        collector.modules.items(.dependencies)[owner] = try collector.edges.toOwnedSlice(collector.allocator);

        _ = collector.temporary.reset(.retain_capacity);

        return collector.targets.items;
    }
};

pub fn readSourceGraphZX(handle: *anyopaque, owner: u64) Collector.Error!void {
    try Scan.borrow(handle).collectZX(@intCast(owner));
}

pub fn readSourceGraphRX(handle: *anyopaque, owner: u64, row: u64, store: bool) Collector.Error!void {
    const scan = Scan.borrow(handle);
    const index: usize = @intCast(row);

    try scan.collectRX(@intCast(owner), if (store) scan.stores[index] else scan.modules[index]);
}

pub fn publishSourceGraphDependencies(handle: *anyopaque, owner: u64) std.mem.Allocator.Error![]const u64 {
    return Scan.borrow(handle).publish(@intCast(owner));
}
