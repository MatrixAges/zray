const std = @import("std");
const zx = @import("zx");
const model = @import("model.zig");
const Self = @This();
const enabled = @import("rx_options").generated_graph;

pub const Request = struct { owner: usize, source: model.Source };
const Edges = struct { targets: []const u64, end: usize };

seen: []u32,
queue: []u64,
sources: model.Sources,
end: usize = 0,

cursor: usize = 0,
edge_end: usize = 0,
pub fn init(allocator: std.mem.Allocator, count: usize, sources: model.Sources) std.mem.Allocator.Error!Self {
    const seen = try allocator.alloc(u32, count);

    errdefer allocator.free(seen);

    const queue = try allocator.alloc(u64, count);

    @memset(seen, 0);

    return .{ .seen = seen, .queue = queue, .sources = sources };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.queue);
    allocator.free(self.seen);
}

pub fn advance(self: *Self, adjacency: *const model.Adjacency, edges: Edges) ?Request {
    if (comptime !enabled) return self.advanceSeed(adjacency, edges);

    const rule = @import("generated_source_graph_frontier");

    const input: std.meta.Child(rule.Input) = .{
        .seen = @ptrCast(&self.seen),
        .queue = @ptrCast(&self.queue),
        .end = self.end,
        .targets = edges.targets,
        .cursor = self.cursor,
        .sources = &.{ .zx_count = self.sources.zx_count, .rx_end = self.sources.rx_end },
        .starts = @ptrCast(&adjacency.starts),
        .ends = @ptrCast(&adjacency.ends),
        .edge_start = self.edge_end,
        .edge_end = edges.end,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    self.end = @intCast(result.end);
    self.cursor = @intCast(result.cursor);
    self.edge_end = edges.end;

    const request = result.request orelse return null;
    const row: usize = @intCast(request.row);

    return .{
        .owner = @intCast(request.owner),
        .source = switch (request.kind) {
            .ZX => .{ .zx = row },
            .RX => .{ .rx = row },
            .Store => .{ .store = row },
        },
    };
}

fn advanceSeed(self: *Self, adjacency: *const model.Adjacency, edges: Edges) ?Request {
    if (self.cursor != 0) {
        const previous: usize = @intCast(self.queue[self.cursor - 1]);
        adjacency.starts[previous] = self.edge_end;
        adjacency.ends[previous] = edges.end;
    }

    self.edge_end = edges.end;

    for (edges.targets) |target| {
        const row: usize = @intCast(target);

        if (self.seen[row] != 0) continue;

        self.seen[row] = 1;
        self.queue[self.end] = target;
        self.end += 1;
    }

    if (self.cursor == self.end) return null;

    const owner: usize = @intCast(self.queue[self.cursor]);

    self.cursor += 1;

    return .{ .owner = owner, .source = self.sources.at(owner) };
}
