const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const Iteration = @import("../iteration_value/root.zig");
const reuse = @import("reuse.zig");
const schedule = @import("schedule.zig");
const evaluation = @import("../expressions/evaluate.zig");
const entry = @import("generated_lower_scope_bindings");
const ScopeAction = evaluation.Api.ScopeAction;
const Error = Lower.Error;

const Regular = struct {
    plan: schedule.Result,
    aliases: *const ?reuse,
    inline_spans: [64]u32 = undefined,
    allocated: ?[]u32 = null,
    spans: schedule.Spans = undefined,
    sequence: ?blocks.Sequence = null,
};

const Iterated = struct {
    context: *Iteration,
    allocator: std.mem.Allocator,
    values: schedule.Values = undefined,
};

const Frame = struct {
    lowering: *Lower,
    scope: ir.ScopeRow,
    state: union(enum) { regular: Regular, iteration: Iterated },
    request: schedule.Request = undefined,
    emitted: node.Block = .{},
    fn run(self: *Frame, layout: bool, result_plan: ?schedule.Result) Error!node.ExpressionId {
        const plan = result_plan orelse schedule.Result{
            .type_id = undefined,
            .candidate = null,
            .count = self.scope.bindings.len,
            .consumed_count = 0,
        };

        const Input = std.meta.Child(entry.Input);
        const Candidate = std.meta.Child(std.meta.Child(@FieldType(Input, "candidate")));

        const candidate: Candidate = if (plan.candidate) |last| .{
            .symbol = @backingInt(last.symbol),
            .value = @backingInt(last.value),
        } else undefined;

        const input: Input = .{
            .frame = @ptrCast(self.lowering),
            .scope = @ptrCast(self),
            .result = @backingInt(self.scope.result),
            .layout = layout,
            .count = plan.count,
            .consumed_count = plan.consumed_count,
            .candidate = if (plan.candidate != null) &candidate else null,
        };

        return evaluation.invoke(entry, &input);
    }
};

pub fn regular(lowering: *Lower, scope: ir.ScopeRow, layout: bool, plan: schedule.Result, aliases: *const ?reuse) Error!node.ExpressionId {
    var frame: Frame = .{ .lowering = lowering, .scope = scope, .state = .{ .regular = .{ .plan = plan, .aliases = aliases } } };
    const ordinary = &frame.state.regular;

    defer if (ordinary.allocated) |allocation| lowering.workspace.free(allocation);
    defer if (ordinary.sequence) |*sequence| sequence.deinit();

    return frame.run(layout, plan);
}

pub fn iteration(context: *Iteration, allocator: std.mem.Allocator, scope: ir.ScopeRow) Error!node.ExpressionId {
    var frame: Frame = .{ .lowering = context.lowering, .scope = scope, .state = .{ .iteration = .{ .context = context, .allocator = allocator } } };

    return frame.run(false, null);
}

fn borrow(handle: *const anyopaque) *Frame {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn consumeScopeResult(handle: *const anyopaque, symbol: u32, value: u32, layout: bool) Error!?u32 {
    const frame = borrow(handle);
    const result = try @import("../iteration_consumer.zig").lower(frame.lowering, @fromBackingInt(symbol), @fromBackingInt(value), frame.scope.result, layout);

    return if (result) |id| @backingInt(id) else null;
}

pub fn beginScopeBindings(handle: *const anyopaque, length: u64) Error!void {
    const frame = borrow(handle);
    const count: usize = @intCast(length);
    frame.request = schedule.begin(count);

    switch (frame.state) {
        .regular => |*state| {
            const total = std.math.mul(usize, count, 2) catch return error.OutOfMemory;

            const spans = if (total <= state.inline_spans.len) state.inline_spans[0..total] else allocated: {
                const allocation = try frame.lowering.workspace.alloc(u32, total);
                state.allocated = allocation;

                break :allocated allocation;
            };

            state.spans = .{ .starts = spans[0..count], .counts = spans[count..] };
        },
        .iteration => |*state| {
            state.values = .{
                .values = try state.allocator.alloc(?u32, count),
                .types = try state.allocator.alloc(?u32, count),
                .names = try state.allocator.alloc([]const u8, count),
            };
        },
    }
}

pub fn advanceScopeBinding(handle: *const anyopaque) ScopeAction {
    const frame = borrow(handle);

    frame.request = switch (frame.state) {
        .regular => |*state| regular_request: {
            const changes = if (state.aliases.*) |active| active.state.changes else &.{};

            break :regular_request schedule.advance(frame.lowering, frame.scope, changes, @as(*const schedule.Spans, &state.spans), &frame.request, frame.emitted);
        },
        .iteration => |*state| schedule.advance(frame.lowering, frame.scope, &.{}, @as(*const schedule.Values, &state.values), &frame.request, frame.emitted),
    };

    frame.emitted = .{};

    comptime view.compatible(@FieldType(schedule.Request, "action"), ScopeAction);

    return @fromBackingInt(@backingInt(frame.request.action));
}

pub fn scopeBindingOperand(handle: *const anyopaque) u32 {
    return borrow(handle).request.value;
}

pub fn scopeBindingType(handle: *const anyopaque) u32 {
    return borrow(handle).request.type_id.?;
}

pub fn reuseScopeBinding(handle: *const anyopaque) Error!void {
    const frame = borrow(handle);
    const item = schedule.binding(frame.request);
    var output: std.ArrayList(node.Statement) = .empty;
    frame.emitted = (try frame.state.regular.aliases.*.?.publish(frame.lowering, &output, item.position)).?;
}

pub fn emitScopeTask(handle: *const anyopaque) Error!void {
    const frame = borrow(handle);
    const item = schedule.binding(frame.request);
    frame.emitted = try @import("../tasks/root.zig").bind(frame.lowering, frame.lowering.names[@backingInt(item.symbol.?)], item.value, false);
}

pub fn prepareScopeBinding(handle: *const anyopaque) Error!?u32 {
    const frame = borrow(handle);
    const self = frame.lowering;
    const ordinary = &frame.state.regular;

    ordinary.sequence = self.builder.statementSequence(self.workspace);

    const symbol = frame.request.symbol orelse return null;
    const value = try @import("../value_call/locals.zig").optionalCall(self, &ordinary.sequence.?, @fromBackingInt(symbol), @fromBackingInt(frame.request.value), ordinary.plan.type_id);

    return if (value) |id| @backingInt(id) else null;
}

pub fn discardScopeOperand(handle: *const anyopaque, operand: u32) Error!u32 {
    return @backingInt(try @import("../iteration.zig").discard(evaluation.borrow(handle), @fromBackingInt(operand)));
}

pub fn publishScopeBinding(handle: *const anyopaque, value: u32, layout: bool) Error!void {
    const frame = borrow(handle);
    const ordinary = &frame.state.regular;
    const item = schedule.binding(frame.request);
    const mutable = if (ordinary.aliases.*) |active| active.variables[item.position] else false;

    frame.emitted = try @import("../binding.zig").publish(frame.lowering, &ordinary.sequence.?, .{
        .symbol = item.symbol,
        .value = @fromBackingInt(value),
        .by_value = layout,
        .scope = true,
        .mutable = mutable,
    });

    ordinary.sequence.?.deinit();

    ordinary.sequence = null;
}

pub fn publishIterationBinding(handle: *const anyopaque, value: u32) void {
    borrow(handle).emitted.start = value;
}

pub fn finishScopeBindings(handle: *const anyopaque, result: u32) Error!u32 {
    const frame = borrow(handle);
    const lowering = frame.lowering;
    const value: node.ExpressionId = @fromBackingInt(result);

    return @backingInt(switch (frame.state) {
        .regular => |state| lowered: {
            const body = try blocks.tail(lowering.allocator, lowering.builder.nodes, state.spans.starts, state.spans.counts);

            break :lowered try @import("../aggregate.zig").finishStored(lowering, body, value, null);
        },
        .iteration => |state| try @import("../iteration_value/scope.zig").emit(lowering, state.allocator, value, &.{
            .symbols = frame.scope.bindings.symbols,
            .values = state.values.values,
            .types = state.values.types,
            .names = state.values.names,
        }),
    });
}
