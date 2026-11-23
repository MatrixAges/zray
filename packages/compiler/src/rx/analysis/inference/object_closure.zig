const std = @import("std");
const Graph = @import("types.zig");
const enabled = @import("rx_options").generated_graph;
const Self = @This();
pub const Query = enum { spread, selection };

const Storage = struct {
    revision: [1]u64 = .{0},
    index: [2][]const u32 = @splat(&.{}),
    edges: [4][]const u64 = @splat(&.{}),
    marks: [3][]const bool = @splat(&.{}),
};

arena: std.heap.ArenaAllocator,
cache: if (enabled) Storage else void = if (enabled) .{} else {},
pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn prove(self: *Self, graph: *const Graph, value: Graph.Id, query: Query) std.mem.Allocator.Error!bool {
    return self.proveRoot(graph, graph.root(value), query);
}

pub fn proveRoot(self: *Self, graph: *const Graph, root: Graph.Id, query: Query) std.mem.Allocator.Error!bool {
    const kind = graph.nodes.items(.kind)[@backingInt(root)];
    const constructions = graph.pending.constructions.len;
    const selections = graph.pending.selections.len;

    if (comptime !enabled) {
        if (kind == .Known) return true;
        if (constructions == 0 and selections == 0) return false;

        return @import("object_closure/seed.zig").prove(graph, root, query, 0);
    }

    return @import("object_closure/host.zig").prove(self, graph, root, kind, constructions, selections, query == .spread);
}
