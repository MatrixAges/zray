const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const intrinsics = @import("intrinsics.zig");

/// Writes one element: in place when the plan proves the target unique, into a copy otherwise, which keeps the header of
/// a headered target.
pub fn lower(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const update = self.program.expression(id).value.list_update;
    var body: std.ArrayList(node.Statement) = .empty;
    const type_id = self.program.expression(update.target).type_id;
    const selected = @import("state_value/list.zig").selected(self, type_id);
    const plan = @import("list_update.zig").bufferPlan(self, id, update.target, selected);
    const lists = @import("state_value/list.zig");
    const source_value = try aggregate.bind(self, &body, try self.expr(update.target));
    const source = try @import("state_value/list.zig").items(self, type_id, source_value);
    const index = try aggregate.bind(self, &body, try self.expr(update.index));

    try intrinsics.failIf(self, &body, try intrinsics.binary(self, .greater_equal, index, try self.field(source, "len")), "IndexOutOfBounds");

    const evaluated = try aggregate.bind(self, &body, try self.expr(update.value));
    const value = try @import("state_value/elements.zig").write(self, &body, type_id, evaluated);
    const element = try @import("state_value/elements.zig").typeExpr(self, type_id);

    const buffer = if (plan.in_place and !plan.deferred)
        try aggregate.bind(self, &body, try self.builtin(.constCast, &.{source}))

    else if (selected) chosen: {
        var copied: std.ArrayList(node.Statement) = .empty;

        const private = if (plan.deferred)
            try @import("growth.zig").copy(self, &copied, element, source, !self.may_grow)
        else
            try @import("growth.zig").reserve(self, &copied, element, source, try self.field(source, "len"), false);

        const allocated = if (plan.deferred or plan.grow)
            try aggregate.finish(self, &copied, private)

        else split: {
            var plain: std.ArrayList(node.Statement) = .empty;
            const duplicated = try aggregate.bind(self, &plain, try self.call(try self.field(try self.builder.identifier("allocator"), "dupe"), &.{ element, source }, true));

            break :split try self.builder.expression(.{ .conditional = .{
                .condition = try lists.headered(self, source_value),
                .yes = try aggregate.finish(self, &copied, private),
                .no = try aggregate.finish(self, &plain, duplicated),
            } });
        };

        const storage = if (plan.transfer) try self.builder.expression(.{ .conditional = .{
            .condition = try lists.writable(self, source_value),
            .yes = try self.builtin(.constCast, &.{source}),
            .no = allocated,
        } }) else allocated;

        break :chosen try aggregate.bind(self, &body, storage);
    } else if (plan.grow)
        try @import("growth.zig").reserve(self, &body, element, source, try self.field(source, "len"), false)
    else
        try aggregate.bind(self, &body, try self.call(try self.field(try self.builder.identifier("allocator"), "dupe"), &.{ element, source }, true));

    const slot = try self.builder.expression(.{ .index = .{ .target = buffer, .index = try self.builtin(.intCast, &.{index}) } });

    try body.append(self.allocator, .{ .assignment = .{ .target = slot, .value = value } });

    const result = if (selected) result: {
        const headered = if (plan.grow or plan.deferred)
            (if (plan.transfer)
                try intrinsics.binary(self, .not_equal, try self.field(source_value, "storage"), try lists.tag(self, .owned))
            else
                try self.builder.expression(.{ .boolean = true }))
        else
            try lists.headered(self, source_value);

        break :result try lists.owned(self, type_id, buffer, headered);
    } else buffer;

    return aggregate.finish(self, &body, result);
}
