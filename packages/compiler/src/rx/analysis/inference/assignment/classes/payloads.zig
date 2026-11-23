const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");

pub const Columns = struct {
    initial: []const u32 = &.{},
    registered: []const u32 = &.{},
};

pub fn collect(graph: *Graph, allocator: std.mem.Allocator) zx.Error!Columns {
    return @import("../application/host.zig").collect(graph, allocator);
}
