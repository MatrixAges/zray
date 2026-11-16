const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const Collector = @import("collect.zig");
const Frontier = @import("frontier.zig");
const model = @import("model.zig");

pub fn run(collector: *Collector, adjacency: *model.Adjacency, roots: []const u64, sources: []const project.Source, modules: []const rx.ModuleSource, stores: []const rx.ModuleSource, shared: ?*project.ParseCache, prefetched: ?*project.ParseCache.Prefetched) Collector.Error!usize {
    const backing = collector.backing;
    var local = project.ParseCache{ .allocator = collector.allocator };

    defer local.deinit();

    const cache = shared orelse &local;
    const paths = collector.modules.items(.path);
    var parsed_modules = try cache.prefetchRegistered(backing, sources, paths[0..sources.len]);

    defer parsed_modules.deinit(backing);

    var pending = try Frontier.init(backing, collector.modules.len, collector.sources);

    defer pending.deinit(backing);

    var reused: usize = 0;
    defer cache.reused += reused;

    var request = pending.advance(adjacency, .{ .targets = roots, .end = 0 });

    while (request) |next| {
        const index = next.owner;
        const module = next.source;

        collector.begin(index, if (module == .zx) sources[module.zx].source else "");

        switch (module) {
            .rx => |source_index| try @import("rx_edges.zig").collect(collector, modules[source_index]),
            .store => |source_index| try @import("rx_edges.zig").collect(collector, stores[source_index]),
            .zx => |source_index| {
                const source = sources[source_index];
                const parsed = parsed_modules.module(source_index);

                reused += 1;

                if (parsed.diagnostic()) |issue| {
                    collector.issue = .{
                        .path = paths[index],
                        .location = rx.sourceLocation(source.source, issue.span.start),
                        .code = @tagName(issue.code),
                        .message = try collector.allocator.dupe(u8, issue.message),
                    };

                    return error.InvalidGraph;
                }

                switch (parsed.*) {
                    .native => |result| try @import("zx_edges.zig").collect(collector, zx.syntax.header.Native{ .program = result.value.parsed.ast }),
                    .indexed => |*result| if (project.ParseCache.indexed_enabled) {
                        const header = result.header();

                        if (comptime @import("rx_options").generated_graph) {
                            try @import("imports/indexed.zig").collect(collector, header);
                        } else {
                            try @import("zx_edges.zig").collect(collector, header);
                        }
                    } else unreachable,
                }
            },
        }

        collector.modules.items(.dependencies)[index] = try collector.edges.toOwnedSlice(collector.allocator);

        const targets = collector.targets.items;

        request = pending.advance(adjacency, .{ .targets = targets[pending.edge_end..], .end = targets.len });
        _ = collector.temporary.reset(.retain_capacity);
    }

    adjacency.targets = collector.targets.items;

    if (prefetched) |output| {
        output.* = parsed_modules;
        parsed_modules = .{};
    }

    return pending.end;
}
