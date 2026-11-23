const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");

pub const Workspace = struct {
    local_frames: [16]u64 = undefined,
    local_values: [32]u32 = undefined,
    extra_frames: std.ArrayList(u64) = .empty,
    extra_values: std.ArrayList(u32) = .empty,
    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.extra_frames.deinit(allocator);
        self.extra_values.deinit(allocator);
    }
};

pub fn resolve(graph: *Graph, value: Graph.Id, workspace: *Workspace) zx.Error!zx.ir.TypeId {
    if (!@import("rx_options").generated_graph) return @import("resolve/seed.zig").resolve(graph, value, 0);

    const rows = graph.nodes.slice();
    const index = @backingInt(graph.root(value));

    if (rows.items(.kind)[index] == .Known) return @fromBackingInt(rows.items(.argument)[index]);

    return @import("resolve/host.zig").run(graph, rows, index, workspace);
}
