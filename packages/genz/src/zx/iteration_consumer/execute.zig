const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;
const policy = @import("policy.zig");
const Phase = evaluation.Api.ConsumerPhase;
const Action = evaluation.Api.ConsumerAction;
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    selected: Consumer,
    iteration: ir.ExprId,
    next: ?Phase = null,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, selected: Consumer, iteration: ir.ExprId) Error!?node.ExpressionId {
    var frame: Frame = .{ .lowering = self, .selected = selected, .iteration = iteration };
    const entry = @import("generated_lower_loop_consumer");
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = try entry.executeIn(empty.allocator(), @ptrCast(&frame));

    return if (result) |id| @fromBackingInt(id) else null;
}

pub fn decideLoopConsumer(handle: *const anyopaque, phase: Phase) Error!Action {
    const frame = Frame.borrow(handle);
    const decision = try policy.decide(frame.lowering, frame.selected, frame.iteration, zx.columns.view(policy.Phase, phase));
    frame.next = if (decision.next) |next| zx.columns.view(Phase, next) else null;

    return zx.columns.view(Action, decision.action);
}

pub fn nextLoopConsumer(handle: *const anyopaque) ?Phase {
    return Frame.borrow(handle).next;
}

pub fn consumeVectorLoop(handle: *const anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const result = try @import("../simd/iteration.zig").lower(frame.lowering, frame.iteration, frame.selected);

    return if (result) |id| @backingInt(id) else null;
}

pub fn consumeLoop(handle: *const anyopaque, scalar: bool) Error!?u32 {
    const frame = Frame.borrow(handle);
    var selected = frame.selected;

    if (scalar) selected.layout = false;

    const result = try @import("../iteration.zig").consume(frame.lowering, frame.iteration, selected);

    return if (result) |id| @backingInt(id) else null;
}
