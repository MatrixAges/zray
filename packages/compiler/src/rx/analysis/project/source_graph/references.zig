const std = @import("std");
const model = @import("model.zig");
const Self = @This();
const Edge = model.Edge;
pub const Match = struct { row: usize, edge: *const Edge };

edges: []const Edge = &.{},
position: usize = 0,
pub fn view(self: *const Self, comptime View: type, reference: model.Reference) View {
    const bytes = std.mem.sliceAsBytes(self.edges);

    return .{
        .roles = if (bytes.len == 0) bytes else bytes[@offsetOf(Edge, "reference")..],
        .stride = @sizeOf(Edge),
        .role = @backingInt(reference),
    };
}

pub fn take(self: *Self, row: usize) Match {
    self.position = row + 1;

    return .{ .row = row, .edge = &self.edges[row] };
}

pub fn next(self: *Self, reference: model.Reference) Match {
    return self.take(self.seedRow(reference));
}

pub fn seedRow(self: *const Self, reference: model.Reference) usize {
    for (self.edges[self.position..], self.position..) |*edge, row| {
        if (edge.reference == reference) return row;
    }

    unreachable;
}
