const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub fn field(self: *Lower, value: node.ExpressionId, seed: node.ExpressionId, name: []const u8) Lower.Error!node.ExpressionId {
    var body: std.ArrayList(node.Statement) = .empty;

    try body.append(self.allocator, .{ .discard = value });

    const pointer = try self.builder.expression(.{ .address_of = try self.field(seed, name) });

    return @import("../aggregate.zig").finish(self, &body, pointer);
}
