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
const Input = if (generated) std.meta.Child(@import("generated_lower_loop").Input) else void;
pub const UpdateScope = if (generated) Api.LoopUpdateScope else enum { None, Projected, Ordinary };

const StateInfo = if (generated) std.meta.Child(@FieldType(Input, "loop_state")) else struct {
    name: []const u8,
    reference: u32,
    forwarded: ?u32,
};

const GuardInfo = if (generated) std.meta.Child(@FieldType(Input, "guard_info")) else struct {
    body: u64,
    condition: u32,
    fallback: u32,
};

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
initial: Initial.Plan = std.mem.zeroes(Initial.Plan),
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
step_scope: union(UpdateScope) {
    None,
    Projected: state_scope.Frame(.Projected),
    Ordinary: state_scope.Frame(.Deferred),
} = .None,
next: Step.Values = undefined,
tracker: ?State.Tracker = undefined,
state_info: StateInfo = .{ .name = &.{}, .reference = 0, .forwarded = null },
guard_info: GuardInfo = .{ .body = 0, .condition = 0, .fallback = 0 },
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

    if (active != .None) closeLoopUpdate(self, active);
}

pub fn restoreSeed(self: *Self) void {
    self.restoreUpdate();

    if (self.initial_scope) |saved| saved.restore();
    if (self.parameters) |parameters| parameters.restore();
    if (self.representation) |saved| saved.restore();
}

pub fn release(self: *Self) void {
    self.restoreUpdate();

    if (self.initial_scope) |saved| saved.restore();

    self.projected_body.deinit();
    restoreParameterContext(self);

    if (self.parameters.flags[0]) {
        if (self.parameters.flags[1]) _ = self.lowering.state_symbols.remove(self.iteration.condition_parameter);
        if (self.parameters.flags[2]) _ = self.lowering.state_symbols.remove(self.iteration.parameter);
        if (self.parameters.flags[3]) _ = self.lowering.stack_symbols.remove(self.iteration.condition_parameter);
        if (self.parameters.flags[4]) _ = self.lowering.stack_symbols.remove(self.iteration.parameter);

        self.lowering.names[@backingInt(self.iteration.parameter)] = self.parameters.previous[1];
        self.lowering.names[@backingInt(self.iteration.condition_parameter)] = self.parameters.previous[0];
    }

    if (self.representation) |saved| saved.restore();

    self.loop.deinit();
    self.body.deinit();
}

pub fn closeLoopUpdate(handle: *anyopaque, active: UpdateScope) void {
    const self = borrow(handle);

    switch (active) {
        .None => return,
        .Projected => self.step_scope.Projected.restore(),
        .Ordinary => {
            self.step_scope.Ordinary.restore();
            restoreParameterContext(self);
        },
    }

    self.step_scope = .None;
}

fn restoreParameterContext(self: *Self) void {
    if (generated) {
        if (self.parameters.context) |saved| saved.restore();
    } else if (self.parameters) |parameters| {
        parameters.restoreContext();
    }
}
