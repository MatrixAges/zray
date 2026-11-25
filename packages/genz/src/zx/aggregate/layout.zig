const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const Projection = @import("../iteration/fields/root.zig");
const Route = enum { Direct, Pointer, Borrowed };

pub const Plan = struct {
    projection: ?*const Projection = null,
    plain: Route = .Direct,
    construct: bool,
    pub fn field(self: Plan, ordinal: usize, index: u32) Route {
        _ = ordinal;

        if (self.projection) |projection| {
            if (projection.borrowed[index]) return .Borrowed;
        }

        return self.plain;
    }
};

pub const Request = struct {
    id: ir.ExprId,
    type_id: ir.TypeId,
    layout_only: bool,
    updated: bool,
    indices: []const u32,
};

pub fn plan(self: *const Lower, scratch: std.mem.Allocator, request: Request) Lower.Error!Plan {
    _ = scratch;

    const selected = self.state_plan.selected[@backingInt(request.type_id)];

    if (request.updated) return .{ .construct = !request.layout_only and !selected };

    const context = if (self.loop_fields) |value| (if (value.expression(request.id)) value else null) else null;

    return .{
        .projection = context,
        .plain = if (self.state_active and !selected) .Pointer else .Direct,
        .construct = !request.layout_only and context == null,
    };
}
