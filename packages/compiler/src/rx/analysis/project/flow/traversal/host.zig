const std = @import("std");
const zx = @import("zx");
const Inference = @import("../../constraints/traversal.zig").Host;
const Lowering = @import("../../../flow_compile/traversal.zig").Host;
const Flow = @import("../../flow.zig");
const InferCall = @import("../../constraints/call.zig");
const LowerCall = @import("../../../flow_compile/call.zig");
const Compiler = @import("../../../flow_compile.zig");
const entry = @import("generated_rx_traverse_flow");
const Input = std.meta.Child(entry.Input);
const Label = Flow.Case.Label.Kind;
const memory = zx.memory;
const Error = error{ OutOfMemory, InvalidSource, InvalidFlow };

pub const View = std.meta.Child(@FieldType(Input, "cursor"));
const Returns = std.meta.Child(@typeInfo(@FieldType(Input, "returns")).optional.child);
const Saved = std.meta.Child(@FieldType(Returns, "saved"));
const ResultRows = std.meta.Child(@typeInfo(@FieldType(Input, "results")).optional.child);
const Coverage = std.meta.Child(@FieldType(Input, "coverage"));

const State = struct {
    target: union(enum) { inference: *Inference, lowering: *Lowering },
    call: union(enum) { inference: InferCall, lowering: LowerCall },
    task: Compiler.TaskOutput = undefined,
    return_value: *const zx.ir.Program = undefined,
    case_label: ?*const zx.ir.Program = null,
    cursor: View = undefined,
    parent_return: Saved = undefined,
    slots: [3]*usize,
    labels: memory.ReadColumn = undefined,
    truth: memory.WriteColumn = undefined,
    stopped: memory.WriteColumn = undefined,
    remaining: memory.WriteColumn = undefined,
    fn borrow(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(target: anytype, plan: *const Flow.Plan) @TypeOf(target.closeCase()) {
    const inference = @TypeOf(target) == *Inference;

    var state: State = .{
        .target = if (inference) .{ .inference = target } else .{ .lowering = target },
        .call = if (inference) .{ .inference = undefined } else .{ .lowering = undefined },
        .slots = if (inference)
            .{ undefined, &target.walker.expression.bindings.len, &target.walker.expression.nonnull.items.len }
        else
            .{ undefined, &target.compiler.bindings.len, &target.compiler.nonnull.items.len },
    };

    const cursor_length: memory.ColumnLengths = state.slots[0..1];
    const lengths: memory.ColumnLengths = state.slots[1..];
    var returned: []bool = if (inference) (&target.walker.returned)[0..1] else &.{};
    var output: []u32 = if (inference) @ptrCast((&target.walker.output)[0..1]) else &.{};
    const returns: Returns = .{ .output = @ptrCast(&output), .returned = @ptrCast(&returned), .saved = &state.parent_return };
    const result_slots: memory.ColumnLengths = if (inference) &.{} else &.{&target.compiler.next_binding};
    const results: ResultRows = .{ .cursor = @ptrCast(&result_slots), .types = if (inference) &.{} else @ptrCast(target.compiler.results.types) };
    const coverage: Coverage = .{ .truth = @ptrCast(&state.truth), .stopped = @ptrCast(&state.stopped), .remaining = @ptrCast(&state.remaining) };

    const input: Input = .{
        .frame = @ptrCast(&state),
        .cursor = &state.cursor,
        .lengths = @ptrCast(&lengths),
        .cursor_length = @ptrCast(&cursor_length),
        .labels = @ptrCast(&state.labels),
        .fallback = @backingInt(Label.Default),
        .coverage = &coverage,
        .returns = if (inference) &returns else null,
        .results = if (inference) null else &results,
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
            const body = !inference and (current.payload == .Root or current.payload == .Task or current.payload == .Case);
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
                .target_start = if (body) current.cursor.end - current.body.count else 0,
                .target_first = if (body) current.body.first else 0,
                .destination = if (inference) 0 else current.destination,
            };

            if (inference and current.payload == .ParallelTask) {
                const task = current.payload.ParallelTask;
                state.parent_return = .{ .output = @backingInt(task.output), .returned = task.returned };
            }

            if (current.payload == .Selection) {
                const selection = &current.payload.Selection;
                const cases = if (inference) selection.cases else target.compiler.plan.selections[selection.item].cases;

                state.labels = memory.borrowNestedColumn(Label, &.{ "label", "kind" }, cases);

                if (inference) {
                    const coverage: []@TypeOf(selection.labels.coverage) = (&selection.labels.coverage)[0..1];

                    state.truth = memory.borrowWriteColumn(?bool, "truth", cases);
                    state.stopped = memory.borrowWriteColumn(bool, "stopped", coverage);
                    state.remaining = memory.borrowWriteColumn(?bool, "remaining", coverage);
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

pub fn registerFlowCall(handle: *const anyopaque, row: u64, visible: bool) Error!?u32 {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try state.call.inference.publish(target.walker, target.callOutputs(target.frame())),
        .lowering => |target| return try state.call.lowering.publish(target.compiler, target.callOutputs(target.frame()), target.compiler.selectedResult(row, visible)),
    }

    return null;
}

pub fn checkFlowParallelCall(handle: *const anyopaque, item: u32, id: u32) Error!void {
    try State.borrow(handle).target.lowering.compiler.checkParallelCall(item, id);
}

pub fn evaluateFlowReturn(handle: *const anyopaque, item: u32) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try target.walker.inferReturn(target.walker.module.plan.results[item]),
        .lowering => |target| state.return_value = try target.evaluateReturn(target.frame(), item),
    }
}

pub inline fn writeFlowStep(handle: *const anyopaque, row: u64, kind: anytype, first: u32, exhaustive: bool, output: anytype) void {
    const state = State.borrow(handle);
    const target = state.target.lowering;
    const task = if (kind == .Task) &state.task else null;
    const frame = target.frame();
    const grouped = kind == .Selection or kind == .Parallel;

    target.compiler.compiled.steps.set(@intCast(row), .{
        .kind = @fromBackingInt(@backingInt(kind)),
        .output = @fromBackingInt(@backingInt(output)),
        .first = if (task) |value| value.body else if (grouped) frame.body.first else first,
        .count = if (grouped) frame.body.count else 0,
        .exhaustive = exhaustive,
        .name = if (task) |value| value.name() else null,
        .value = switch (kind) {
            .Return => state.return_value,
            .Task => state.task.value,
            .Selection => frame.payload.Selection.subject,
            else => null,
        },
    });
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

pub fn prepareFlowTaskOutput(handle: *const anyopaque) Compiler.Error!bool {
    const state = State.borrow(handle);

    return state.target.lowering.prepareTaskOutput(&state.task);
}

pub fn evaluateFlowTaskOutput(handle: *const anyopaque, row: u64, visible: bool) Compiler.Error!void {
    const state = State.borrow(handle);
    const target = state.target.lowering;

    try target.evaluateTaskOutput(&state.task, target.compiler.selectedResult(row, visible));
}

pub fn inferFlowTaskOutput(handle: *const anyopaque, parallel: bool) Error!?u32 {
    const target = State.borrow(handle).target.inference;
    const walker = target.walker;
    const frame = target.frame();
    const task = &walker.module.plan.tasks[if (parallel) frame.payload.ParallelTask.item else frame.payload.Task.item];
    const output = if (parallel) try walker.parallelTaskOutput(task) else try walker.taskOutput(task);

    return if (output) |value| @backingInt(value) else null;
}

pub fn requestParallelTaskOutput(handle: *const anyopaque) Error!void {
    const target = State.borrow(handle).target.inference;
    const walker = target.walker;
    const task = &walker.module.plan.tasks[target.frame().payload.ParallelTask.item];

    try walker.requestTaskOutput(task);
}

pub fn bindFlowTaskOutput(handle: *const anyopaque, parallel: bool, value: ?u32) Error!void {
    const output = value orelse return;
    const target = State.borrow(handle).target.inference;
    const walker = target.walker;
    const index = if (parallel) target.frame().payload.ParallelTask.item else target.frame().payload.Task.item;
    const outputs = if (parallel) &target.stack.items[target.stack.items.len - 2].payload.Parallel else &walker.expression.bindings;

    try walker.bindTaskOutput(&walker.module.plan.tasks[index], @fromBackingInt(output), outputs);
}

pub fn finishLoweredFlowTask(handle: *const anyopaque) Compiler.Error!?bool {
    const state = State.borrow(handle);

    return state.task.publish(state.target.lowering.compiler);
}

pub fn mergeFlowParallelBindings(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        .inference => |target| try target.closeParallel(),
        .lowering => |target| try target.mergeParallelBindings(),
    }
}

pub fn checkFlowSelection(handle: *const anyopaque) Compiler.Error!bool {
    return State.borrow(handle).target.lowering.checkSelection();
}

pub fn finishFlowCase(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!void {
    return State.borrow(handle).target.lowering.publishCase(@intCast(row));
}

pub fn popFlowFrame(handle: *const anyopaque) void {
    switch (State.borrow(handle).target) {
        inline else => |target| target.pop(),
    }
}
