const std = @import("std");
const Graph = @import("types.zig");
const enabled = @import("rx_options").generated_graph;
const Self = @This();

const Storage = struct {
    revision: u64 = 0,
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
