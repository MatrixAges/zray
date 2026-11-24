const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const seed_calls = @import("growth/call_seed.zig");
pub const reserve = seed_calls.reserve;
pub const reserveBounded = seed_calls.reserveBounded;
pub const copy = seed_calls.copy;
pub const retract = seed_calls.retract;

/// The value of `id` with the lists the plan renews in it moved to growth buffers of their own, where a value read out of
/// a list or another opaque source enters the values that later appends extend.
pub fn renewValue(self: *Lower, id: ir.ExprId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("growth/value_seed.zig").renewValue(self, id, value);

    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    const name = try self.fresh("renewed");
    const renewed = try self.builder.identifier(name);
    const source = if (self.state_active) try @import("state_value/ownership.zig").clip(self, &body, id, value) else value;

    try body.append(try self.builder.statements(&.{.{ .variable = .{ .name = name, .value = source } }}));
    try @import("growth/delivery.zig").appendValue(self, &body, id, renewed);

    return aggregate.finish(self, &body, renewed);
}

/// One growth copy of a plain list the plan found flowing into appends, so they extend it in place from then on.
pub fn normalize(self: *Lower, id: ir.ExprId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("growth/normalize_seed.zig").normalize(self, id, value);
    if (self.iteration_value) |context| if (context.buffered(self.program.expression(id).type_id)) return value;

    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    const type_id = self.program.expression(id).type_id;
    const child = self.program.typeOf(type_id).list;

    const element = if (self.state_active)
        try @import("state_value/elements.zig").typeExpr(self, type_id)
    else
        try @import("iteration_value/types.zig").element(self, child);

    const selected = @import("state_value/list.zig").selected(self, type_id);
    const qualified = if (selected) try @import("state_value/ownership.zig").clip(self, &body, id, value) else value;
    const serial = self.serial;
    const layout = if (selected) try @import("types.zig").get(self, self.state_types, type_id) else null;

    std.debug.assert(serial == self.serial);

    const result = try @import("growth/delivery.zig").normalize(self, &body, element, qualified, selected, layout);

    return aggregate.finish(self, &body, result);
}
