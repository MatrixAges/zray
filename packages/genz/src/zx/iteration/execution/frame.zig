const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Context = @import("../../iteration_value/root.zig");
const Consumer = @import("../../iteration_consumer.zig").Consumer;
const SeedParameters = @import("../parameters_seed.zig");
const Fields = @import("../fields/root.zig");
const Result = @import("../result.zig");
const State = @import("../state.zig");
const state_scope = @import("../../state_value/scope.zig");
const Represented = @typeInfo(@TypeOf(@import("../../state_value/root.zig").enter)).@"fn".return_type.?;
const InitialGuard = @import("../../iteration_value/initial.zig");
const Initial = @import("../initial.zig");
const Selection = @import("../../iteration_layout/select.zig").Selection;
const Step = @import("../step.zig");
const generated = @import("genz_options").generated_analysis;
const Api = @import("../../expressions/evaluate.zig").Api;
pub const UpdateScope = if (generated) Api.LoopUpdateScope else enum { None, Projected, Ordinary };
const Self = @This();

const Parameters = struct {
    previous: [2][]const u8 = undefined,
    flags: [5]bool = @splat(false),
    context: ?state_scope.Frame(.Iteration) = null,
};

lowering: *Lower,
id: ir.ExprId,
iteration: ir.Iteration,
mode: Result.Mode,
consumer: ?Consumer,
body: Context.Statements,
loop: Context.Statements,
projected_body: Context.Statements,
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
changed_name: []const u8 = &.{},
parameters: if (generated) Parameters else ?SeedParameters = if (generated) .{} else null,
initial_state: node.ExpressionId = undefined,
schedule: if (generated) void else Step.Plan = undefined,
renewal_workspace: *@import("../../growth/renew_workspace.zig") = undefined,
step_scope: union(UpdateScope) {
    None,
    Projected: state_scope.Frame(.Projected),
    Ordinary: state_scope.Frame(.Deferred),
} = .None,
next: Step.Values = undefined,
tracker: ?State.Tracker = undefined,
prefix: Result.Prefix = .{},
update: node.Block = undefined,
growth: node.Block = .{},
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
    };
}

pub fn statements(lowering: *Lower) Context.Statements {
    return if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;
}

pub fn borrow(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}

pub fn output(self: *Self) *Context.Statements {
    return if (self.fields != null) &self.projected_body else &self.body;
}

pub fn restoreUpdate(self: *Self) void {
    const active: UpdateScope = self.step_scope;

    if (active != .None) {
        closeLoopUpdate(self, active);

        if (active == .Ordinary) {
            restoreLoopParameterContext(self);
        }
    }
}

pub fn restoreSeed(self: *Self) void {
    self.restoreUpdate();

    if (self.initial_scope) |saved| saved.restore();
    if (self.parameters) |parameters| parameters.restore();
    if (self.representation) |saved| saved.restore();
}

pub fn loopUpdateScope(handle: *anyopaque) UpdateScope {
    return borrow(handle).step_scope;
}

pub fn closeLoopUpdate(handle: *anyopaque, active: UpdateScope) void {
    const self = borrow(handle);

    switch (active) {
        .None => unreachable,
        .Projected => self.step_scope.Projected.restore(),
        .Ordinary => self.step_scope.Ordinary.restore(),
    }

    self.step_scope = .None;
}

pub fn restoreLoopParameterContext(handle: *anyopaque) void {
    const self = borrow(handle);

    if (generated) {
        if (self.parameters.context) |saved| saved.restore();
    } else if (self.parameters) |parameters| {
        parameters.restoreContext();
    }
}

pub fn closeLoopInitial(handle: *anyopaque) void {
    if (borrow(handle).initial_scope) |saved| saved.restore();
}

pub fn releaseLoopScratch(handle: *anyopaque) void {
    const self = borrow(handle);

    self.projected_body.deinit();
}

pub fn closeLoopRepresentation(handle: *anyopaque) void {
    if (borrow(handle).representation) |saved| saved.restore();
}

pub fn releaseLoopStatements(handle: *anyopaque) void {
    const self = borrow(handle);

    self.loop.deinit();
    self.body.deinit();
}
