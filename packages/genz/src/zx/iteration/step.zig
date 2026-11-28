const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Fields = @import("fields/root.zig");

pub const Input = struct {
    condition: u32,
    body: u32,
    forwarded: ?u32,
    postcondition: bool,
    projected: bool,
    selected_state: bool,
    layout: bool,
    discard: bool,
};

pub const Plan = struct {
    step: u32,
    by_value: bool,
    condition: u32,
    first_test: ?u32,
    after_step: bool,
    restore_projected: bool,
    assignment: enum { Direct, State, Projected },
};

pub const Values = struct { condition: node.ExpressionId, value: node.ExpressionId, first: ?node.ExpressionId };

pub const Write = struct {
    type_id: ir.TypeId,
    origin: ir.ExprId,
    target: node.ExpressionId,
    value: node.ExpressionId,
    fields: ?*const Fields = null,
};

pub fn store(self: *Lower, body: *@import("../iteration_value/root.zig").Statements, schedule: Plan, write: Write, tracker: ?@import("state.zig").Tracker) Lower.Error!node.Block {
    const value = switch (schedule.assignment) {
        .Direct => write.value,
        .Projected => try write.fields.?.qualify(self, body, write.origin, write.value),
        .State => try @import("../state_value/ownership.zig").clip(self, body, write.origin, write.value),
    };

    if (schedule.assignment == .State) {
        try @import("assignment_seed.zig").append(self, body, write.type_id, write.target, value);
    } else {
        try body.append(self.allocator, .{ .assignment = .{ .target = write.target, .value = value } });
    }

    if (tracker) |flag| try flag.markSeed(self, body);

    return self.builder.statements(body.items);
}

pub fn plan(input: Input) Plan {
    return .{
        .step = if (input.projected) input.body else input.forwarded orelse input.body,
        .by_value = input.projected or input.forwarded != null or input.layout,
        .condition = input.condition,
        .first_test = if (input.projected and !input.postcondition) input.condition else null,
        .after_step = input.projected or input.postcondition,
        .restore_projected = input.projected and !input.discard,
        .assignment = if (input.projected) .Projected else if (input.selected_state) .State else .Direct,
    };
}
