const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Context = @import("../../iteration_value/root.zig");
const Consumer = @import("../../iteration_consumer.zig").Consumer;
const Parameters = @import("../parameters.zig");
const Fields = @import("../fields/root.zig");
const Result = @import("../result.zig");
const State = @import("../state.zig");
const state_scope = @import("../../state_value/scope.zig");
const Represented = @typeInfo(@TypeOf(@import("../../state_value/root.zig").enter)).@"fn".return_type.?;
const InitialGuard = @import("../../iteration_value/initial.zig");
const Initial = @import("../initial.zig");
const Selection = @import("../../iteration_layout/select.zig").Selection;
const Step = @import("../step.zig");
const Renewal = @import("../renewal.zig");
const generated = @import("genz_options").generated_analysis;
const Api = @import("../../expressions/evaluate.zig").Api;

pub const Operands = if (generated) Api.LoopOperands else struct {
    condition: u32,
    body: u32,
    by_value: bool,
};

const Self = @This();

lowering: *Lower,
id: ir.ExprId,
iteration: ir.Iteration,
mode: Result.Mode,
consumer: ?Consumer,
body: Context.Statements,
loop: Context.Statements,
projected_body: Context.Statements,
renewal_arena: std.heap.ArenaAllocator,
name: []const u8 = undefined,
state: node.ExpressionId = undefined,
selection: Selection = undefined,
type_id: ir.TypeId = undefined,
initial: Initial.Plan = undefined,
context: Context = undefined,
initial_scope: ?state_scope.Frame(.Iteration) = null,
initial_value: node.ExpressionId = undefined,
guard: ?InitialGuard = null,
representation: @typeInfo(Represented).error_union.payload = null,
seed: node.ExpressionId = undefined,
fields: ?Fields = null,
changed_name: []const u8 = undefined,
parameters: ?Parameters = null,
initial_state: node.ExpressionId = undefined,
schedule: Step.Plan = undefined,
operands: Operands = undefined,
renewal_buffer: [256]u8 = undefined,
renewals: Renewal.Plan = undefined,
step_scope: union(enum) {
    none,
    projected: state_scope.Frame(.Projected),
    ordinary: state_scope.Frame(.Deferred),
} = .none,
next: Step.Values = undefined,
tracker: ?State.Tracker = undefined,
prefix: Result.Prefix = .{},
update: node.Block = undefined,
growth: node.Block = undefined,
recovered: node.ExpressionId = undefined,
pub fn create(lowering: *Lower, id: ir.ExprId, iteration: ir.Iteration, mode: Result.Mode, consumer: ?Consumer) Self {
    return .{
        .lowering = lowering,
        .id = id,
        .iteration = iteration,
        .mode = mode,
        .consumer = consumer,
        .body = statements(lowering),
        .loop = statements(lowering),
        .projected_body = statements(lowering),
        .renewal_arena = .init(lowering.workspace),
    };
}

pub fn statements(lowering: *Lower) Context.Statements {
    return if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;
}

pub fn borrow(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn output(self: *Self) *Context.Statements {
    return if (self.fields != null) &self.projected_body else &self.body;
}

pub fn restoreUpdate(self: *Self) void {
    switch (self.step_scope) {
        .none => {},
        .projected => |saved| saved.restore(),
        .ordinary => |saved| {
            saved.restore();
            self.parameters.?.restoreContext();
        },
    }

    self.step_scope = .none;
}

pub fn restore(self: *Self) void {
    self.restoreUpdate();

    if (self.initial_scope) |saved| saved.restore();
    if (generated) self.projected_body.deinit();

    self.renewal_arena.deinit();

    if (self.parameters) |parameters| parameters.restore();
    if (self.representation) |saved| saved.restore();

    if (generated) {
        self.loop.deinit();
        self.body.deinit();
    }
}
