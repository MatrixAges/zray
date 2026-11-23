const std = @import("std");
const zx = @import("zx");
const Inference = @import("../../constraints/traversal.zig").Host;
const Lowering = @import("../../../flow_compile/traversal.zig").Host;
const Flow = @import("../../flow.zig");
const InferCall = @import("../../constraints/call.zig");
const LowerCall = @import("../../../flow_compile/call.zig");
const Graph = @import("../../../inference/types.zig");
const Compiler = @import("../../../flow_compile.zig");
const entry = @import("generated_rx_traverse_flow");
const Input = std.meta.Child(entry.Input);
const Label = Flow.Case.Label.Kind;
const memory = zx.memory;
const Error = error{ OutOfMemory, InvalidSource, InvalidFlow };

pub const View = std.meta.Child(@FieldType(Input, "cursor"));

const State = struct {
    target: union(enum) { inference: *Inference, lowering: *Lowering },
    call: union(enum) { inference: InferCall, lowering: LowerCall },
    task: union(enum) { inference: ?Graph.Id, lowering: Compiler.TaskOutput },
    return_value: *const zx.ir.Program = undefined,
    case_label: ?*const zx.ir.Program = null,
    cursor: View = undefined,
    slots: [3]*usize,
    labels: memory.ReadColumn = undefined,
    fn borrow(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(target: anytype, plan: *const Flow.Plan) @TypeOf(target.closeCase(true)) {
    const inference = @TypeOf(target) == *Inference;

    var state: State = .{
        .target = if (inference) .{ .inference = target } else .{ .lowering = target },
        .call = if (inference) .{ .inference = undefined } else .{ .lowering = undefined },
        .task = if (inference) .{ .inference = null } else .{ .lowering = undefined },
        .slots = if (inference)
            .{ undefined, &target.walker.expression.bindings.len, &target.walker.expression.nonnull.items.len }
        else
            .{ undefined, &target.compiler.bindings.len, &target.compiler.nonnull.items.len },
    };

    const cursor_length: memory.ColumnLengths = state.slots[0..1];
    const lengths: memory.ColumnLengths = state.slots[1..];

    const input: Input = .{
        .frame = @ptrCast(&state),
        .cursor = &state.cursor,
        .lengths = @ptrCast(&lengths),
        .cursor_length = @ptrCast(&cursor_length),
        .labels = @ptrCast(&state.labels),
        .fallback = @backingInt(Label.Default),
        .inference = inference,
        .kinds = plan.kinds,
        .items = plan.items,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeValue(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.InvalidSource, error.InvalidFlow => @errorCast(err),
        else => unreachable,
    };
}

pub fn refreshFlowCursor(handle: *const anyopaque) void {
    const state = State.borrow(handle);

    switch (state.target) {
        inline else => |target| {
            const current = target.frame();
            const inference = @TypeOf(target) == *Inference;

            state.slots[0] = &current.cursor.first;

            state.cursor = .{
                .first = current.cursor.first,
                .end = current.cursor.end,
                .region = std.meta.activeTag(current.payload),
                .saved_bindings = switch (current.payload) {
                    .Task => |task| task.bindings,
                    .ParallelTask => |task| if (inference) task.bindings else 0,
                    .Case => |case| case.bindings,
                    else => 0,
                },
                .saved_facts = if (current.payload == .Case) current.payload.Case.facts else 0,
                .case_remaining = null,
                .case_stopped = false,
            };

            if (current.payload == .Selection) {
                const selection = &current.payload.Selection;
                const cases = if (inference) selection.cases else target.compiler.plan.selections[selection.item].cases;

                state.labels = memory.borrowNestedColumn(Label, &.{ "label", "kind" }, cases);

                if (inference) {
                    state.cursor.case_remaining = selection.labels.coverage.remaining;
                    state.cursor.case_stopped = selection.labels.coverage.stopped;
                }
            }
        },
    }
}

pub fn prepareFlowCall(handle: *const anyopaque, item: u32) Error!bool {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| {
            try InferCall.prepare(target.walker, item, &state.call.inference);

            return state.call.inference.invocation.input != null;
        },
        .lowering => |target| {
            try LowerCall.prepare(target.compiler, item, &state.call.lowering);

            return state.call.lowering.input != null;
        },
    }
}

fn callEffect(comptime method: []const u8) fn (*const anyopaque) Error!void {
    return struct {
        fn apply(handle: *const anyopaque) Error!void {
            const state = State.borrow(handle);

            switch (state.target) {
                .inference => |target| try @field(InferCall, method)(&state.call.inference, target.walker),
                .lowering => |target| try @field(LowerCall, method)(&state.call.lowering, target.compiler),
            }
        }
    }.apply;
}

pub const bindFlowGetters = callEffect("bindGetters");
pub const evaluateFlowArgument = callEffect("argument");
pub const createFlowUnitArgument = callEffect("unit");

pub fn publishFlowCall(handle: *const anyopaque, row: u64) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try state.call.inference.publish(target.walker, target.callOutputs(target.frame())),
        .lowering => |target| {
            const current = target.frame();
            const id = try state.call.lowering.publish(target.compiler, target.callOutputs(current));

            try target.writeCall(current, @intCast(row), state.call.lowering.row, id);
        },
    }
}

pub fn evaluateFlowReturn(handle: *const anyopaque, item: u32) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try target.walker.inferReturn(target.walker.module.plan.results[item]),
        .lowering => |target| state.return_value = try target.evaluateReturn(target.frame(), item),
    }
}

pub fn publishFlowReturn(handle: *const anyopaque, row: u64) void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| target.walker.returned = true,
        .lowering => |target| target.writeReturn(target.frame(), @intCast(row), state.return_value),
    }
}

pub fn openFlowTask(handle: *const anyopaque, row: u64, item: u32, parallel: bool) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.task(target.frame(), @intCast(row), item, parallel),
    }
}

fn openRegion(comptime method: []const u8) fn (*const anyopaque, u64, u32) Error!void {
    return struct {
        fn apply(handle: *const anyopaque, row: u64, item: u32) Error!void {
            switch (State.borrow(handle).target) {
                inline else => |target| try @field(@TypeOf(target.*), method)(target, target.frame(), @intCast(row), item),
            }
        }
    }.apply;
}

pub const openFlowParallel = openRegion("parallel");
pub const openFlowSelection = openRegion("selection");

pub fn evaluateFlowCaseLabel(handle: *const anyopaque, row: u64) Error!?bool {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| return target.labelCase(target.frame(), @intCast(row)),
        .lowering => |target| state.case_label = try target.labelCase(target.frame(), @intCast(row)),
    }

    return null;
}

pub fn readFlowConditionLabel(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!?bool {
    const selected = &State.borrow(handle).target.inference.frame().payload.Selection;

    return selected.labels.lookAhead(selected.cases[@intCast(row)].label.attribute().?);
}

pub fn publishFlowCaseCoverage(handle: *const anyopaque, row: u64, fallback: bool, stopped: bool, remaining: ?bool) void {
    const selected = &State.borrow(handle).target.inference.frame().payload.Selection;

    selected.labels.coverage = .{ .stopped = stopped, .remaining = remaining };

    if (fallback) selected.cases[@intCast(row)].truth = remaining;
}

pub fn refineFlowCase(handle: *const anyopaque, row: u64) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.refineCase(target.frame(), @intCast(row)),
    }
}

pub fn pushFlowCase(handle: *const anyopaque, row: u64, bindings: u64, facts: u64) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try target.pushCase(target.frame(), @intCast(row), @intCast(bindings), @intCast(facts)),
        .lowering => |target| try target.pushCase(target.frame(), @intCast(row), @intCast(bindings), @intCast(facts), state.case_label),
    }
}

pub fn prepareFlowTaskOutput(handle: *const anyopaque) Error!bool {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| {
            state.task.inference = null;

            return target.walker.module.plan.tasks[target.frame().payload.Task.item].output != null;
        },
        .lowering => |target| return target.prepareTaskOutput(&state.task.lowering),
    }
}

pub fn evaluateFlowTaskOutput(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| {
            const walker = target.walker;
            const task = &walker.module.plan.tasks[target.frame().payload.Task.item];
            state.task.inference = try walker.taskOutput(task);
        },
        .lowering => |target| try target.evaluateTaskOutput(&state.task.lowering),
    }
}

pub fn inferParallelTaskOutput(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);
    const target = state.target.inference;
    const walker = target.walker;
    const task = &walker.module.plan.tasks[target.frame().payload.ParallelTask.item];

    state.task.inference = try walker.parallelTaskOutput(task);
}

pub fn requestParallelTaskOutput(handle: *const anyopaque) Error!void {
    const target = State.borrow(handle).target.inference;
    const walker = target.walker;
    const task = &walker.module.plan.tasks[target.frame().payload.ParallelTask.item];

    try walker.requestTaskOutput(task);
}

pub fn restoreParallelTaskReturn(handle: *const anyopaque) void {
    const target = State.borrow(handle).target.inference;
    const saved = target.frame().payload.ParallelTask;

    target.walker.output = saved.output;
    target.walker.returned = saved.returned;
}

pub fn publishFlowTaskOutput(handle: *const anyopaque, parallel: bool) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| {
            const output = state.task.inference orelse return;
            const walker = target.walker;
            const index = if (parallel) target.frame().payload.ParallelTask.item else target.frame().payload.Task.item;
            const outputs = if (parallel) &target.stack.items[target.stack.items.len - 2].payload.Parallel else &walker.expression.bindings;

            try walker.bindTaskOutput(&walker.module.plan.tasks[index], output, outputs);
        },
        .lowering => |target| try target.publishTaskOutput(&state.task.lowering),
    }
}

pub fn closeFlowParallel(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeParallel(),
    }
}

pub fn completeFlowBranch(handle: *const anyopaque, selection: bool) Error!void {
    const target = State.borrow(handle).target;

    if (target != .lowering) return;

    return if (selection) target.lowering.closeSelection() else target.lowering.closeCase(false);
}

pub fn popFlowFrame(handle: *const anyopaque) void {
    switch (State.borrow(handle).target) {
        inline else => |target| target.pop(),
    }
}
