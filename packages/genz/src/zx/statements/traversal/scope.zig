const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const publication = @import("../../construction/publication.zig");
const locals = @import("../../value_call/locals.zig");
const Self = @This();

values: ir.Block,
spans: []u64,
registered: ?locals.Registered = null,

active: bool = false,
pub fn open(lowering: *Lower, values: ir.Block, spans: []u64) Lower.Error!Self {
    var scope: Self = .{ .values = values, .spans = spans, .active = true };

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
    self.spans[offset] = publication.packSpan(span);
}

pub fn finish(self: *const Self, lowering: *Lower) Lower.Error!node.Block {
    if (self.values.len == 0) return .{};

    return @import("../../../node/blocks.zig").joinStatementSpans(lowering.allocator, lowering.builder.nodes, self.spans, false);
}
