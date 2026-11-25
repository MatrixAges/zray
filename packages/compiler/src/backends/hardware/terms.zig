const std = @import("std");
const ir = @import("ir.zig");
const limits = @import("generated_hardware_limits").@"zx.constants";
const Index = @import("terms/index.zig");
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{InvalidHardwareTerm};
pub const max_nodes: usize = limits.maximum_nodes;

allocator: std.mem.Allocator,
scratch: std.mem.Allocator,
nodes: std.ArrayList(ir.Node) = .empty,
variables: Index = .empty,
cache: Index = .empty,
origin: ?ir.Origin = null,
pub fn add(self: *Self, node: ir.Node) Error!ir.Id {
    if (self.nodes.items.len >= max_nodes or node.sort.width == 0 or node.sort.width > limits.maximum_bit_width) return error.InvalidHardwareTerm;

    return self.append(node);
}

pub fn append(self: *Self, node: ir.Node) std.mem.Allocator.Error!ir.Id {
    const id: ir.Id = @fromBackingInt(@intCast(self.nodes.items.len));
    var located = node;
    located.origin = self.origin;

    try self.nodes.append(self.allocator, located);

    return id;
}

pub fn intern(self: *Self, key: []const u8, node: ir.Node) Error!ir.Id {
    if (self.cache.get(key)) |existing| return existing;

    try self.cache.ensureUnusedCapacity(self.scratch, 1);

    const id = try self.add(node);

    self.cache.putAssumeCapacityNoClobber(key, id);

    return id;
}

pub fn fromSourceError(err: error{ OutOfMemory, IndexOutOfBounds, IntegerOverflow }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexOutOfBounds, error.IntegerOverflow => error.InvalidHardwareTerm,
    };
}
