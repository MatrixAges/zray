const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;
const entry = @import("generated_aggregate_sequence");

const Policy = if (generated) @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload else struct {
    element: enum { Direct, List, Pointer },
    result: enum { List, Tuple, LayoutTuple, Template },
};

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.ExpressionRow, items: []const ir.ExprId, layout: bool) Lower.Error!node.ExpressionId {
    const plan = policy(self, id, value, layout);

    if (plan.result == .List) {
        if (try @import("../static_list.zig").lower(self, value, items)) |literal| {
            return @import("../state_value/list.zig").wrap(self, value.type_id, literal, false);
        }
    }

    var body: std.ArrayList(node.Statement) = .empty;
    const expressions = try self.allocator.alloc(node.ExpressionId, items.len);

    for (items, expressions) |item, *expression| {
        const bound = try aggregate.bind(self, &body, try self.expr(item));

        expression.* = switch (plan.element) {
            .Direct => bound,
            .List => try @import("../state_value/elements.zig").write(self, &body, value.type_id, bound),
            .Pointer => try @import("../state_value/conversion.zig").convert(self, &body, self.program.expression(item).type_id, bound, .pointer),
        };
    }

    const result = switch (plan.result) {
        .Tuple, .LayoutTuple => tuple: {
            const tuple = try @import("literals.zig").tuple(self, expressions);

            break :tuple if (plan.result == .LayoutTuple) try @import("../state_value/origin.zig").tuple(self, value.type_id, tuple) else try self.construct(value.type_id, tuple);
        },
        .List => list: {
            const list = try @import("list.zig").literal(self, value.type_id, expressions);

            break :list try @import("../state_value/list.zig").wrap(self, value.type_id, list, false);
        },
        .Template => try @import("../templates.zig").lower(self, items, expressions),
    };

    return aggregate.finish(self, &body, result);
}

fn policy(self: *const Lower, id: ir.ExprId, value: ir.ExpressionRow, layout: bool) Policy {
    const selected = value.value == .tuple and self.state_active and self.state_plan.selected[@backingInt(value.type_id)];

    if (!generated) return switch (value.value) {
        .list => .{ .element = .List, .result = .List },
        .tuple => .{ .element = if (self.state_active and !selected) .Pointer else .Direct, .result = if (layout) .LayoutTuple else .Tuple },
        .template => .{ .element = .Direct, .result = .Template },
        else => unreachable,
    };

    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .kind = zx.columns.view(@FieldType(Input, "kind"), self.program.expressions.kinds[@backingInt(id)]),
        .layout = layout,
        .state_active = self.state_active,
        .selected = selected,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;
}
