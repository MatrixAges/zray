const std = @import("std");
const zx = @import("zx");
const Inference = @import("../../constraints/traversal.zig").Host;
const Lowering = @import("../../../flow_compile/traversal.zig").Host;
const Flow = @import("../../flow.zig");
const InferCall = @import("../../constraints/call.zig");
const LowerCall = @import("../../../flow_compile/call.zig");
const Compiler = @import("../../../flow_compile.zig");
const execution = @import("../../workflow/execute.zig");
const entry = @import("generated_rx_traverse_flow");
const Input = std.meta.Child(entry.Input);
const Label = Flow.Case.Label.Kind;
const memory = zx.memory;
const Error = error{ OutOfMemory, InvalidSource, InvalidFlow };

pub const View = std.meta.Child(@FieldType(Input, "cursor"));
const Lengths = std.meta.Child(@FieldType(Input, "lengths"));
const Saved = std.meta.Child(@typeInfo(@FieldType(Input, "returns")).optional.child);
const ResultRows = std.meta.Child(@typeInfo(@FieldType(Input, "results")).optional.child);

const State = struct {
    target: union(enum) { inference: *Inference, lowering: *Lowering },
    call: union(enum) { inference: InferCall, lowering: LowerCall },
    task: Compiler.TaskOutput = undefined,
    return_value: *const zx.ir.Program = undefined,
    case_label: ?*const zx.ir.Program = null,
    cursor: View = undefined,
    parent_return: Saved = undefined,
    slots: [2]*usize,
    lengths: Lengths = undefined,
    results: ?ResultRows,
    labels: memory.ReadColumn = undefined,
    fn refreshLengths(self: *State) void {
        self.lengths = .{ .bindings = self.slots[0].*, .facts = self.slots[1].* };

        if (self.results) |*results| results.row = self.target.lowering.compiler.next_binding;
    }
    fn shrink(self: *State, slot: usize, length: u64) void {
        const target = self.slots[slot];

        std.debug.assert(length <= target.*);

        target.* = @intCast(length);
    }
};

pub fn run(target: anytype, plan: *const Flow.Plan) @TypeOf(target.closeCase()) {
    const inference = @TypeOf(target) == *Inference;

    var state: State = .{
        .target = if (inference) .{ .inference = target } else .{ .lowering = target },
        .call = if (inference) .{ .inference = undefined } else .{ .lowering = undefined },
        .slots = if (inference)
            .{ &target.walker.expression.bindings.len, &target.walker.expression.nonnull.items.len }
        else
            .{ &target.compiler.bindings.len, &target.compiler.nonnull.items.len },
        .results = if (inference) null else .{ .row = undefined, .types = @ptrCast(target.compiler.results.types) },
    };

    state.refreshLengths();

    const input: Input = .{
        .cursor = &state.cursor,
        .lengths = &state.lengths,
        .labels = @ptrCast(&state.labels),
        .fallback = @backingInt(Label.Default),
        .returns = if (inference) &state.parent_return else null,
        .results = if (state.results) |*results| results else null,
        .kinds = plan.kinds,
        .items = plan.items,
    };

    const Store = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

    const Host = struct {
        state: *State,
        reply: *std.meta.Child(Store),
        store_0: *Store,
        pub fn commit(host: *@This(), pending: entry.zx_pending) Error!void {
            const effect = pending.store_0 orelse return;
            const work = host.state;

            switch (effect.step) {
                .Refresh => refreshFlowCursor(work, effect.next),
                .PrepareCall => host.reply.flag = try prepareFlowCall(work, effect.item.?),
                .BindGetters => try callEffect(work, "bindGetters"),
                .EvaluateArgument => try callEffect(work, "argument"),
                .CreateUnit => try callEffect(work, "unit"),
                .RegisterCall => host.reply.result_id = try registerFlowCall(work, effect.row.?, effect.visible.?, effect.next, effect.bindings.?),
                .CheckCall => try work.target.lowering.compiler.checkParallelCall(effect.item.?, effect.id.?),
                .EvaluateReturn => try evaluateFlowReturn(work, effect.item.?, effect.returned.?),
                .Publish => writeFlowStep(work, effect.row.?, effect.kind.?, effect.first.?, effect.exhaustive.?, effect.output.?),
                .OpenTask => try openFlowTask(work, effect.row.?, effect.item.?, effect.parallel.?),
                .OpenParallel => try openRegion(work, "parallel", effect.row.?, effect.item.?),
                .OpenSelection => try openRegion(work, "selection", effect.row.?, effect.item.?),
                .EvaluateLabel => host.reply.truth = try evaluateFlowCaseLabel(work, effect.row.?),
                .ReadLabel => host.reply.truth = try readFlowConditionLabel(work, effect.row.?),
                .RefineCase => try refineFlowCase(work, effect.row.?, effect.coverage),
                .PushCase => try pushFlowCase(work, effect.row.?, effect.bindings.?, effect.facts.?),
                .PrepareTaskOutput => host.reply.flag = try work.target.lowering.prepareTaskOutput(&work.task),
                .EvaluateTaskOutput => try evaluateFlowTaskOutput(work, effect.row.?, effect.visible.?, effect.next),
                .InferTaskOutput => host.reply.result_id = try inferFlowTaskOutput(work, effect.parallel.?),
                .RequestTaskOutput => try requestParallelTaskOutput(work, effect.value.?, effect.returned.?),
                .BindTaskOutput => try bindFlowTaskOutput(work, effect.parallel.?, effect.value, effect.bindings.?),
                .FinishTask => host.reply.truth = try finishLoweredFlowTask(work, effect.bindings.?),
                .MergeBindings => try mergeFlowParallelBindings(work),
                .CheckSelection => host.reply.flag = try work.target.lowering.checkSelection(),
                .FinishCase => try finishFlowCase(work, effect.row, effect.facts.?, effect.bindings.?),
                .Pop => popFlowFrame(work),
            }

            work.refreshLengths();
        }
    };

    var reply = execution.snapshot(std.meta.Child(Store), .{ .step = .Refresh, .flag = false });
    var store: Store = &reply;
    var host: Host = .{ .state = &state, .reply = &reply, .store_0 = &store };
    var scratch_buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(target.memory);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    return entry.executeIn(fallback.allocator(), &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.OutOfMemory, error.InvalidSource, error.InvalidFlow => @errorCast(err),
        else => unreachable,
    };
}

fn refreshFlowCursor(state: *State, next: ?u64) void {
    switch (state.target) {
        inline else => |target| {
            const current = target.frame();
            const inference = @TypeOf(target) == *Inference;
            const body = !inference and (current.payload == .Root or current.payload == .Task or current.payload == .Case);

            if (next) |position| {
                current.cursor.first = @intCast(position);

                return;
            }

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
                    state.cursor.case_remaining = selection.labels.coverage.remaining;
                    state.cursor.case_stopped = selection.labels.coverage.stopped;
                }
            }
        },
    }
}

fn prepareFlowCall(state: *State, item: u32) Error!bool {
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

fn callEffect(state: *State, comptime method: []const u8) Error!void {
    switch (state.target) {
        .inference => |target| try @field(InferCall, method)(&state.call.inference, target.walker),
        .lowering => |target| try @field(LowerCall, method)(&state.call.lowering, target.compiler),
    }
}

fn registerFlowCall(state: *State, row: u64, visible: bool, next: ?u64, bindings: u64) Error!?u32 {
    state.shrink(0, bindings);

    switch (state.target) {
        .inference => |target| try state.call.inference.publish(target.walker, target.callOutputs(target.frame())),
        .lowering => |target| {
            target.compiler.next_binding = @intCast(next.?);

            return try state.call.lowering.publish(target.compiler, target.callOutputs(target.frame()), target.compiler.selectedResult(row, visible));
        },
    }

    return null;
}

fn evaluateFlowReturn(state: *State, item: u32, returned: bool) Error!void {
    switch (state.target) {
        .inference => |target| {
            try target.walker.inferReturn(target.walker.module.plan.results[item]);

            target.walker.returned = returned;
        },
        .lowering => |target| state.return_value = try target.evaluateReturn(target.frame(), item),
    }
}

fn writeFlowStep(state: *State, row: u64, kind: anytype, first: u32, exhaustive: bool, output: anytype) void {
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

fn openFlowTask(state: *State, row: u64, item: u32, parallel: bool) Error!void {
    switch (state.target) {
        inline else => |target| try target.task(target.frame(), @intCast(row), item, parallel),
    }
}

fn openRegion(state: *State, comptime method: []const u8, row: u64, item: u32) Error!void {
    switch (state.target) {
        inline else => |target| try @field(@TypeOf(target.*), method)(target, target.frame(), @intCast(row), item),
    }
}

fn evaluateFlowCaseLabel(state: *State, row: u64) Error!?bool {
    switch (state.target) {
        .inference => |target| return target.labelCase(target.frame(), @intCast(row)),
        .lowering => |target| state.case_label = try target.labelCase(target.frame(), @intCast(row)),
    }

    return null;
}

fn readFlowConditionLabel(state: *State, row: u64) std.mem.Allocator.Error!?bool {
    const selected = &state.target.inference.frame().payload.Selection;

    return selected.labels.lookAhead(selected.cases[@intCast(row)].label.attribute().?);
}

fn refineFlowCase(state: *State, row: u64, coverage: anytype) Error!void {
    if (coverage) |update| {
        const selection = &state.target.inference.frame().payload.Selection;

        selection.cases[@intCast(row)].truth = update.truth;

        if (update.stopped) |stopped| {
            selection.labels.coverage.stopped = stopped;
            selection.labels.coverage.remaining = update.remaining;
        }
    }

    switch (state.target) {
        inline else => |target| try target.refineCase(target.frame(), @intCast(row)),
    }
}

fn pushFlowCase(state: *State, row: u64, bindings: u64, facts: u64) Error!void {
    switch (state.target) {
        .inference => |target| try target.pushCase(target.frame(), @intCast(row), @intCast(bindings), @intCast(facts)),
        .lowering => |target| try target.pushCase(target.frame(), @intCast(row), @intCast(bindings), @intCast(facts), state.case_label),
    }
}

fn evaluateFlowTaskOutput(state: *State, row: u64, visible: bool, next: ?u64) Compiler.Error!void {
    const target = state.target.lowering;

    target.compiler.next_binding = @intCast(next.?);

    try target.evaluateTaskOutput(&state.task, target.compiler.selectedResult(row, visible));
}

fn inferFlowTaskOutput(state: *State, parallel: bool) Error!?u32 {
    const target = state.target.inference;
    const walker = target.walker;
    const frame = target.frame();
    const task = &walker.module.plan.tasks[if (parallel) frame.payload.ParallelTask.item else frame.payload.Task.item];
    const output = if (parallel) try walker.parallelTaskOutput(task) else try walker.taskOutput(task);

    return if (output) |value| @backingInt(value) else null;
}

fn requestParallelTaskOutput(state: *State, output: u32, returned: bool) Error!void {
    const target = state.target.inference;
    const walker = target.walker;
    const task = &walker.module.plan.tasks[target.frame().payload.ParallelTask.item];

    try walker.requestTaskOutput(task);

    walker.output = @fromBackingInt(output);
    walker.returned = returned;
}

fn bindFlowTaskOutput(state: *State, parallel: bool, value: ?u32, bindings: u64) Error!void {
    state.shrink(0, bindings);

    const output = value orelse return;
    const target = state.target.inference;
    const walker = target.walker;
    const index = if (parallel) target.frame().payload.ParallelTask.item else target.frame().payload.Task.item;
    const outputs = if (parallel) &target.stack.items[target.stack.items.len - 2].payload.Parallel else &walker.expression.bindings;

    try walker.bindTaskOutput(&walker.module.plan.tasks[index], @fromBackingInt(output), outputs);
}

fn finishLoweredFlowTask(state: *State, bindings: u64) Compiler.Error!?bool {
    state.shrink(0, bindings);

    return state.task.publish(state.target.lowering.compiler);
}

fn mergeFlowParallelBindings(state: *State) Error!void {
    switch (state.target) {
        .inference => |target| try target.closeParallel(),
        .lowering => |target| try target.mergeParallelBindings(),
    }
}

fn finishFlowCase(state: *State, row: ?u64, facts: u64, bindings: u64) std.mem.Allocator.Error!void {
    if (row) |index| try state.target.lowering.publishCase(@intCast(index));

    state.shrink(1, facts);
    state.shrink(0, bindings);
}

fn popFlowFrame(state: *State) void {
    switch (state.target) {
        inline else => |target| target.pop(),
    }
}
