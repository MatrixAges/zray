const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const consumer = @import("../iteration_consumer.zig");
const Guard = @import("../iteration/initial.zig").Guard;
const scope = @import("../state_value/scope.zig");
const name_scope = @import("../scope/reuse.zig");
const generated = @import("genz_options").generated_analysis;
const Self = @This();

body: node.Block,
condition: node.ExpressionId,
result: node.ExpressionId,
pub fn create(lowering: *Lower, body: *@import("root.zig").Statements, iteration: ir.Iteration, selected: ?consumer.Consumer, initial: node.ExpressionId, guard: Guard) Lower.Error!Self {
    const outer = if (generated) try body.block(lowering.allocator) else try lowering.builder.statements(body.items);

    body.clearRetainingCapacity();

    const name = lowering.builder.nodes.get(initial).identifier;
    const index = @backingInt(iteration.condition_parameter);
    var names: [1][]const u8 = undefined;

    const binding = if (generated) name_scope.bindNames(lowering, &.{iteration.condition_parameter}, &.{name}, &names) else seed: {
        names[0] = lowering.names[index];
        lowering.names[index] = name;

        break :seed null;
    };

    defer {
        if (generated) binding.restore(lowering) else lowering.names[index] = names[0];
    }

    const view = scope.enter(lowering, .Iteration, .{ .iteration_value = null });

    defer view.restore();

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
