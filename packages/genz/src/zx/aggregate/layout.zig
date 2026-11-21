const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const Projection = @import("../iteration/fields/root.zig");
const generated = @import("genz_options").generated_analysis;
const entry = @import("generated_object_layout_plan");
const Output = if (generated) std.meta.Child(entry.Output) else void;
const Route = if (generated) @typeInfo(@FieldType(Output, "routes")).pointer.child else enum { Direct, Pointer, Borrowed };

pub const Plan = struct {
    projection: ?*const Projection = null,
    plain: Route = .Direct,
    routes: []const Route = &.{},
    construct: bool,
    pub fn field(self: Plan, ordinal: usize, index: u32) Route {
        if (!generated) {
            if (self.projection) |projection| {
                if (projection.borrowed[index]) return .Borrowed;
            }

            return self.plain;
        }

        return if (self.routes.len == 0) self.plain else self.routes[ordinal];
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
    const selected = self.state_plan.selected[@backingInt(request.type_id)];

    if (!generated) return seed(self, request.id, request.layout_only, request.updated, selected);

    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .expression = @backingInt(request.id),
        .loop_states = if (self.loop_fields) |context| context.states else null,
        .state_active = self.state_active,
        .selected = selected,
        .layout_only = request.layout_only,
        .updated = request.updated,
        .indices = request.indices,
        .borrowed = if (self.loop_fields) |context| context.borrowed else null,
    };

    const output = zx.columns.invoke(entry.executeValue, scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .projection = if (output.project) self.loop_fields else null,
        .plain = output.plain,
        .routes = output.routes,
        .construct = output.construct,
    };
}

fn seed(self: *const Lower, id: ir.ExprId, layout_only: bool, updated: bool, selected: bool) Plan {
    if (updated) return .{ .construct = !layout_only and !selected };

    const context = if (self.loop_fields) |value| (if (value.expression(id)) value else null) else null;

    return .{
        .projection = context,
        .plain = if (self.state_active and !selected) .Pointer else .Direct,
        .construct = !layout_only and context == null,
    };
}
