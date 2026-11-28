const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Self = @import("lower.zig");

pub fn construct(self: *Self, type_id: ir.TypeId, value: node.ExpressionId) Self.Error!node.ExpressionId {
    const referenced = self.state_plan.referenced(type_id);
    const selected = @import("state_value/root.zig").selected(self, type_id);
    const layout = try self.layoutExpr(type_id);
    const prepared = if (selected) try @import("state_value/origin_seed.zig").tuple(self, type_id, value) else value;
    const result = try self.cast(layout, prepared);
    var body: std.ArrayList(node.Statement) = .empty;

    if (referenced) {
        const name = try self.fresh("state_reference");
        const slot = try self.builder.identifier(name);

        try self.reference_storage.append(self.allocator, .{ .variable = .{
            .name = name,
            .type_expr = layout,
            .value = try self.builder.expression(.undefined_value),
        } });

        try body.append(self.allocator, .{ .assignment = .{ .target = slot, .value = result } });

        return @import("aggregate.zig").finish(self, &body, try self.builder.expression(.{ .address_of = slot }));
    }

    if (selected) return result;

    const pointer = try @import("aggregate.zig").bind(self, &body, try self.call(try self.field(try self.builder.identifier("allocator"), "create"), &.{layout}, true));

    try body.append(self.allocator, .{ .assignment = .{ .target = try self.builder.expression(.{ .dereference = pointer }), .value = result } });

    return @import("aggregate.zig").finish(self, &body, try self.cast(try self.typeExpr(type_id), pointer));
}
