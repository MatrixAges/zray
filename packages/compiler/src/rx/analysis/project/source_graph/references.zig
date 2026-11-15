const std = @import("std");
const zx = @import("zx");
const model = @import("model.zig");
const Self = @This();
const Edge = model.Edge;
pub const Match = struct { row: usize, edge: *const Edge };

edges: []const Edge = &.{},
position: usize = 0,
pub fn next(self: *Self, reference: model.Reference) Match {
    const remaining = self.edges[self.position..];

    const index = if (comptime @import("rx_options").generated_graph)
        indexed(remaining, reference)
    else
        seed(remaining, reference);

    const row = self.position + index;

    self.position = row + 1;

    return .{ .row = row, .edge = &self.edges[row] };
}

fn indexed(remaining: []const Edge, reference: model.Reference) usize {
    if (remaining.len == 0) unreachable;

    const rule = @import("generated_rx_next_reference");

    const input: std.meta.Child(rule.Input) = .{
        .roles = std.mem.sliceAsBytes(remaining)[@offsetOf(Edge, "reference")..],
        .stride = @sizeOf(Edge),
        .role = @backingInt(reference),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return @intCast(result orelse unreachable);
}

fn seed(remaining: []const Edge, reference: model.Reference) usize {
    for (remaining, 0..) |*edge, row| if (edge.reference == reference) return row;

    unreachable;
}
