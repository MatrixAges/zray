const std = @import("std");
const model = @import("model.zig");
const Self = @This();
const Edges = struct { targets: []const u64, end: usize };

seen: []u32,
queue: []u64,
end: usize = 0,

cursor: usize = 0,
edge_end: usize = 0,
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    const seen = try allocator.alloc(u32, count);

    errdefer allocator.free(seen);

    const queue = try allocator.alloc(u64, count);

    @memset(seen, 0);

    return .{ .seen = seen, .queue = queue };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.queue);
    allocator.free(self.seen);
}

pub fn advance(self: *Self, adjacency: *const model.Adjacency, edges: Edges) ?usize {
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

    return owner;
}
