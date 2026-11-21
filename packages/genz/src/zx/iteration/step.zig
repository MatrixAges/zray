const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Fields = @import("fields/root.zig");
const Parameters = @import("parameters.zig");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_iteration_step") else struct {};

pub const Input = if (generated) std.meta.Child(entry.Input) else struct {
    condition: u32,
    body: u32,
    forwarded: ?u32,
    postcondition: bool,
    projected: bool,
    selected_state: bool,
    layout: bool,
    buffered: bool,
    discard: bool,
};

const Plan = if (generated) std.meta.Child(entry.Output) else struct {
    step: u32,
    by_value: bool,
    condition: u32,
    first_test: ?u32,
    after_step: bool,
    classify_renewals: bool,
    inline_lists: bool,
    restore_projected: bool,
    assignment: enum { Direct, State, Projected },
};

pub fn plan(input: Input) Plan {
    if (comptime !generated) return seed(input);

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

    return .{
        .step = result.step,
        .by_value = result.by_value,
        .condition = result.condition,
        .first_test = result.first_test,
        .after_step = result.after_step,
        .classify_renewals = result.classify_renewals,
        .inline_lists = result.inline_lists,
        .restore_projected = result.restore_projected,
        .assignment = result.assignment,
    };
}

const Values = struct { condition: node.ExpressionId, value: node.ExpressionId, first: ?node.ExpressionId };

pub const Scope = union(enum) {
    projected: struct { fields: *const Fields, name: []const u8, seed: []const u8 },
    ordinary: bool,
};

pub fn lower(self: *Lower, schedule: Plan, parameters: *const Parameters, scope: Scope) Lower.Error!Values {
    const frame = @import("../state_value/scope.zig");

    switch (scope) {
        .projected => |projected| {
            const first = if (schedule.first_test) |condition| initial: {
                parameters.rename(projected.seed);
                defer parameters.rename(projected.name);

                break :initial try self.expr(@fromBackingInt(condition));
            } else null;

            const saved = frame.enter(self, .Projected, .{ .loop_fields = projected.fields });

            defer saved.restore();

            return evaluate(self, schedule, first);
        },
        .ordinary => |deferred| {
            const saved = frame.enter(self, .Deferred, .{ .deferred_lists = deferred });

            defer {
                saved.restore();
                parameters.restoreContext();
            }

            return evaluate(self, schedule, null);
        },
    }
}

fn evaluate(self: *Lower, schedule: Plan, first: ?node.ExpressionId) Lower.Error!Values {
    const test_value = try self.expr(@fromBackingInt(schedule.condition));
    const body: ir.ExprId = @fromBackingInt(schedule.step);
    const value = if (schedule.by_value) try @import("../value_call/root.zig").expression(self, body) else try self.expr(body);

    return .{ .condition = test_value, .value = value, .first = first };
}

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

    if (!generated) {
        if (schedule.assignment == .State) {
            try @import("assignment_seed.zig").append(self, body, write.type_id, write.target, value);
        } else {
            try body.append(self.allocator, .{ .assignment = .{ .target = write.target, .value = value } });
        }

        if (tracker) |flag| try flag.markSeed(self, body);

        return self.builder.statements(body.items);
    }

    const prefix = try self.builder.finishStatements(body);

    const count = try @import("assignment.zig").lower(self, .{
        .type_id = write.type_id,
        .active = schedule.assignment == .State and self.state_active,
        .target = write.target,
        .value = value,
        .mark = if (tracker) |flag| flag.generated else null,
    });

    return .{ .start = prefix.start, .len = prefix.len + count };
}

fn seed(input: Input) Plan {
    return .{
        .step = if (input.projected) input.body else input.forwarded orelse input.body,
        .by_value = input.projected or input.forwarded != null or input.layout,
        .condition = input.condition,
        .first_test = if (input.projected and !input.postcondition) input.condition else null,
        .after_step = input.projected or input.postcondition,
        .classify_renewals = !input.projected and input.selected_state and input.forwarded == null,
        .inline_lists = !input.projected and input.buffered,
        .restore_projected = input.projected and !input.discard,
        .assignment = if (input.projected) .Projected else if (input.selected_state) .State else .Direct,
    };
}
