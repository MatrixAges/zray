const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const consumer = @import("../iteration_consumer.zig");
const Guard = @import("../iteration/initial.zig").Guard;
const Self = @This();

body: node.Block,
condition: node.ExpressionId,
result: node.ExpressionId,
pub fn create(lowering: *Lower, body: *std.ArrayList(node.Statement), iteration: ir.Iteration, selected: ?consumer.Consumer, initial: node.ExpressionId, guard: Guard) Lower.Error!Self {
    const outer = try lowering.builder.statements(body.items);

    body.clearRetainingCapacity();

    const name = lowering.builder.nodes.get(initial).identifier;
    const index = @backingInt(iteration.condition_parameter);
    const previous_name = lowering.names[index];
    const previous_context = lowering.iteration_value;
    lowering.names[index] = name;
    lowering.iteration_value = null;
    defer lowering.names[index] = previous_name;
    defer lowering.iteration_value = previous_context;

    const condition = try lowering.expr(iteration.condition);

    const result = switch (guard) {
        .Consumer => try @import("result.zig").lower(lowering, selected.?, initial),
        .Unit => try lowering.builder.expression(.unit),
        .None => unreachable,
    };

    return .{ .body = outer, .condition = condition, .result = result };
}

pub fn finish(self: *Self, lowering: *Lower, result: node.ExpressionId) Lower.Error!node.ExpressionId {
    const body = try @import("../../node/blocks.zig").tail(
        lowering.allocator,
        lowering.builder.nodes,
        &.{self.body.start},
        &.{self.body.len},
    );

    return aggregate.finishStored(lowering, body, result, .{ .condition = self.condition, .fallback = self.result });
}
