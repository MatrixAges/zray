const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const Context = @import("../iteration_value/root.zig");
const scope_state = @import("../state_value/scope.zig");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_iteration_parameters") else struct {};
const Input = if (generated) std.meta.Child(entry.Input) else void;
pub const Layout = if (generated) @FieldType(Input, "layout") else enum { Plain, Stack, State, Deep };

const Plan = if (generated) std.meta.Child(entry.Output) else struct {
    add_condition: bool,
    add_step: bool,
    remove_state_condition: bool,
    remove_state_step: bool,
    remove_stack_condition: bool,
    remove_stack_step: bool,
    condition_name: []const u8,
    step_name: []const u8,
};

const Self = @This();

lowering: *Lower,
condition: ir.SymbolId,
step: ir.SymbolId,
context: ?scope_state.Frame(.Iteration) = null,
plan: Plan,
pub fn enter(lowering: *Lower, iteration: ir.Iteration, layout: Layout, name: []const u8, context: *Context) Lower.Error!Self {
    var scope = bind(lowering, iteration, layout, name);

    errdefer scope.restore();

    if (layout == .Plain) return scope;
    try scope.addMembers(layout, context);
    if (layout == .Deep) scope.openContext(context);

    return scope;
}

pub fn bind(lowering: *Lower, iteration: ir.Iteration, layout: Layout, name: []const u8) Self {
    const condition = iteration.condition_parameter;
    const step = iteration.parameter;

    return .{
        .lowering = lowering,
        .condition = condition,
        .step = step,
        .plan = bindNames(lowering, layout, condition, step, name),
    };
}

pub fn addMembers(self: Self, layout: Layout, context: *Context) Lower.Error!void {
    const lowering = self.lowering;

    const symbols = switch (layout) {
        .Plain => unreachable,
        .State => &lowering.state_symbols,
        .Stack => &lowering.stack_symbols,
        .Deep => &context.symbols,
    };

    const ids = [_]ir.SymbolId{ self.condition, self.step };

    try symbols.addMany(lowering.allocator, members(&ids, self.plan.add_condition, self.plan.add_step));
}

pub fn openContext(self: *Self, context: *Context) void {
    self.context = scope_state.enter(self.lowering, .Iteration, .{ .iteration_value = context });
}

pub fn rename(self: Self, name: []const u8) void {
    self.writeNames(name, name);
}

pub fn restoreContext(self: Self) void {
    if (self.context) |scope| scope.restore();
}

pub fn restore(self: Self) void {
    self.restoreContext();

    if (generated) return self.restoreStorage();
    if (self.plan.remove_state_condition) _ = self.lowering.state_symbols.remove(self.condition);
    if (self.plan.remove_state_step) _ = self.lowering.state_symbols.remove(self.step);
    if (self.plan.remove_stack_condition) _ = self.lowering.stack_symbols.remove(self.condition);
    if (self.plan.remove_stack_step) _ = self.lowering.stack_symbols.remove(self.step);

    self.writeNames(self.plan.condition_name, self.plan.step_name);
}

fn restoreStorage(self: Self) void {
    const operation = @import("generated_iteration_parameters_restore");
    const Restore = std.meta.Child(operation.Input);
    const Mutable = std.meta.Child(@FieldType(Restore, "state"));
    const state = self.lowering.state_symbols.current();
    const stack = self.lowering.stack_symbols.current();
    const state_view = @import("../members.zig").writable(Mutable, state);
    const stack_view = @import("../members.zig").writable(Mutable, stack);

    const input: Restore = .{
        .target = @ptrCast(&self.lowering.names),
        .state = &state_view,
        .stack = &stack_view,
        .condition = @backingInt(self.condition),
        .step = @backingInt(self.step),
        .condition_name = self.plan.condition_name,
        .step_name = self.plan.step_name,
        .remove_state_condition = self.plan.remove_state_condition,
        .remove_state_step = self.plan.remove_state_step,
        .remove_stack_condition = self.plan.remove_stack_condition,
        .remove_stack_step = self.plan.remove_stack_step,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const output = zx.columns.invoke(operation.executeValue, fixed.allocator(), &input) catch unreachable;

    state.count = output.state;
    stack.count = output.stack;
}

fn members(ids: *const [2]ir.SymbolId, have_condition: bool, have_step: bool) []const ir.SymbolId {
    const first = @intFromBool(!have_condition);
    const end = ids.len - @intFromBool(!have_step);

    return ids[first..end];
}

fn writeNames(self: Self, condition: []const u8, step: []const u8) void {
    if (!generated) {
        self.lowering.names[@backingInt(self.step)] = step;
        self.lowering.names[@backingInt(self.condition)] = condition;

        return;
    }

    const operation = @import("generated_iteration_parameters_rename");

    const input: std.meta.Child(operation.Input) = .{
        .target = @ptrCast(&self.lowering.names),
        .condition = @backingInt(self.condition),
        .step = @backingInt(self.step),
        .condition_name = condition,
        .step_name = step,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(operation.executeValue, fixed.allocator(), &input) catch unreachable;
}

fn bindNames(lowering: *Lower, layout: Layout, condition: ir.SymbolId, step: ir.SymbolId, name: []const u8) Plan {
    if (comptime !generated) {
        const plan = seed(lowering, layout, condition, step);

        lowering.names[@backingInt(condition)] = name;
        lowering.names[@backingInt(step)] = name;

        return plan;
    }

    const Index = std.meta.Child(@FieldType(Input, "state"));
    const state = lowering.state_symbols.view(Index);
    const stack = lowering.stack_symbols.view(Index);

    const input: Input = .{
        .layout = layout,
        .condition = @backingInt(condition),
        .step = @backingInt(step),
        .state = &state,
        .stack = &stack,
        .target = @ptrCast(&lowering.names),
        .name = name,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const output = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

    return zx.columns.view(Plan, output);
}

fn seed(lowering: *const Lower, layout: Layout, condition: ir.SymbolId, step: ir.SymbolId) Plan {
    const state = layout == .State;
    const stack = state or layout == .Stack;
    const distinct = condition != step;
    const remove_state_condition = state and !lowering.state_symbols.contains(condition);
    const remove_state_step = state and distinct and !lowering.state_symbols.contains(step);
    const remove_stack_condition = stack and !lowering.stack_symbols.contains(condition);
    const remove_stack_step = stack and distinct and !lowering.stack_symbols.contains(step);

    return .{
        .add_condition = switch (layout) {
            .Plain => false,
            .State => remove_state_condition,
            .Stack => remove_stack_condition,
            .Deep => true,
        },
        .add_step = switch (layout) {
            .Plain => false,
            .State => remove_state_step,
            .Stack => remove_stack_step,
            .Deep => distinct,
        },
        .remove_state_condition = remove_state_condition,
        .remove_state_step = remove_state_step,
        .remove_stack_condition = remove_stack_condition,
        .remove_stack_step = remove_stack_step,
        .condition_name = lowering.names[@backingInt(condition)],
        .step_name = lowering.names[@backingInt(step)],
    };
}
