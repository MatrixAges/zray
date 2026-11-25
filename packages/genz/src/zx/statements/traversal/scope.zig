const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const locals = @import("../../value_call/locals.zig");
const Self = @This();

values: ir.Block,
starts: []u32,
counts: []u32,
registered: ?locals.Registered = null,

active: bool = false,
pub const Buffer = struct {
    starts: []u32,
    counts: []u32,
};

pub fn open(lowering: *Lower, values: ir.Block, buffer: Buffer) Lower.Error!Self {
    var scope: Self = .{ .values = values, .starts = buffer.starts, .counts = buffer.counts, .active = true };

    if (values.len == 0) return scope;

    scope.registered = try locals.register(lowering, values);

    return scope;
}

pub fn close(self: *Self, lowering: *Lower) void {
    if (!self.active) return;

    self.active = false;

    if (self.registered) |registered| registered.release(lowering);
}

pub fn put(self: *Self, offset: usize, span: node.Block) void {
    self.starts[offset] = span.start;
    self.counts[offset] = span.len;
}

pub fn finish(self: *const Self, lowering: *Lower) Lower.Error!node.Block {
    if (self.values.len == 0) return .{};

    return @import("../../../node/blocks.zig").join(lowering.allocator, lowering.builder.nodes, self.starts, self.counts);
}
