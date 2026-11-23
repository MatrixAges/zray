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
const Error = error{ OutOfMemory, InvalidSource, InvalidFlow };

pub const View = std.meta.Child(@FieldType(Input, "cursor"));

const State = struct {
    target: union(enum) { inference: *Inference, lowering: *Lowering },
    call: union(enum) { inference: InferCall, lowering: LowerCall },
    task: union(enum) { inference: ?Graph.Id, lowering: Compiler.TaskOutput },
    return_value: *const zx.ir.Program = undefined,
    case_label: ?*const zx.ir.Program = null,
    cursor: View = undefined,
    fn borrow(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(target: anytype, plan: *const Flow.Plan) @TypeOf(target.closeCase()) {
    const inference = @TypeOf(target) == *Inference;

    var state: State = .{
        .target = if (inference) .{ .inference = target } else .{ .lowering = target },
        .call = if (inference) .{ .inference = undefined } else .{ .lowering = undefined },
        .task = if (inference) .{ .inference = null } else .{ .lowering = undefined },
    };

    const input: Input = .{
        .frame = @ptrCast(&state),
        .cursor = &state.cursor,
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

            state.cursor = .{
                .first = current.cursor.first,
                .end = current.cursor.end,
                .region = std.meta.activeTag(current.payload),
            };
        },
    }
}

pub fn saveFlowCursor(handle: *const anyopaque, next: u64) void {
    switch (State.borrow(handle).target) {
        inline else => |target| target.frame().cursor.first = @intCast(next),
    }
}

pub fn flowBindingCount(handle: *const anyopaque) u64 {
    return switch (State.borrow(handle).target) {
        .inference => |target| target.walker.expression.bindings.len,
        .lowering => |target| target.compiler.bindings.len,
    };
}

pub fn restoreFlowBindings(handle: *const anyopaque, count: u64) void {
    const length: usize = @intCast(count);

    switch (State.borrow(handle).target) {
        .inference => |target| target.walker.expression.bindings.shrinkRetainingCapacity(length),
        .lowering => |target| target.compiler.bindings.len = length,
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

pub fn bindFlowGetters(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try state.call.inference.bindGetters(target.walker),
        .lowering => |target| try state.call.lowering.bindGetters(target.compiler),
    }
}

pub fn evaluateFlowArgument(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try state.call.inference.argument(target.walker),
        .lowering => |target| try state.call.lowering.argument(target.compiler),
    }
}

pub fn createFlowUnitArgument(handle: *const anyopaque) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try state.call.inference.unit(target.walker),
        .lowering => |target| try state.call.lowering.unit(target.compiler),
    }
}

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

pub fn openFlowParallel(handle: *const anyopaque, row: u64, item: u32) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.parallel(target.frame(), @intCast(row), item),
    }
}

pub fn openFlowSelection(handle: *const anyopaque, row: u64, item: u32) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.selection(target.frame(), @intCast(row), item),
    }
}

pub fn flowCaseIsDefault(handle: *const anyopaque, row: u64) bool {
    const state = State.borrow(handle);

    return switch (state.target) {
        .inference => |target| target.frame().payload.Selection.cases[row].label.kind == .Default,
        .lowering => |target| target.compiler.plan.selections[target.frame().payload.Selection.item].cases[row].label.kind == .Default,
    };
}

pub fn evaluateFlowCaseLabel(handle: *const anyopaque, row: u64) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try target.labelCase(target.frame(), @intCast(row)),
        .lowering => |target| {
            const selected = &target.frame().payload.Selection;
            const compiler = target.compiler;
            const case = &compiler.plan.selections[selected.item].cases[row];
            state.case_label = try compiler.keep(try compiler.value(case.label.attribute().?, selected.subject.output_type, false));
        },
    }
}

pub fn evaluateFlowDefaultCase(handle: *const anyopaque, row: u64) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try target.defaultCase(target.frame(), @intCast(row)),
        .lowering => state.case_label = null,
    }
}

pub fn refineFlowCase(handle: *const anyopaque, row: u64) Error!u64 {
    const state = State.borrow(handle);

    return switch (state.target) {
        .inference => |target| try target.refineCase(target.frame(), @intCast(row)),
        .lowering => |target| block: {
            const selected = &target.frame().payload.Selection;
            const case = &target.compiler.plan.selections[selected.item].cases[row];

            break :block try target.compiler.refineCase(case, &selected.parsed);
        },
    };
}

pub fn pushFlowCase(handle: *const anyopaque, row: u64, bindings: u64, facts: u64) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        .inference => |target| try target.pushCase(target.frame(), @intCast(row), @intCast(bindings), @intCast(facts)),
        .lowering => |target| try target.pushCase(target.frame(), @intCast(row), @intCast(bindings), .{ .facts = @intCast(facts), .label = state.case_label }),
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

pub fn savedTaskBindings(handle: *const anyopaque, parallel: bool) u64 {
    return switch (State.borrow(handle).target) {
        .inference => |target| if (parallel) target.frame().payload.ParallelTask.bindings else target.frame().payload.Task.bindings,
        .lowering => |target| target.frame().payload.Task.bindings,
    };
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

pub fn closeFlowSelection(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeSelection(),
    }
}

pub fn closeFlowCase(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeCase(),
    }
}

pub fn popFlowFrame(handle: *const anyopaque) void {
    switch (State.borrow(handle).target) {
        inline else => |target| target.pop(),
    }
}
