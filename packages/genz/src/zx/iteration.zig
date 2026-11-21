const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const Consumer = @import("iteration_consumer.zig").Consumer;
const result = @import("iteration/result.zig");
const Frame = @import("iteration/execution/frame.zig");
const prepare = @import("iteration/execution/prepare.zig");
const emit = @import("iteration/execution/emission.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, id: ir.ExprId, iteration: ir.Iteration) Lower.Error!node.ExpressionId {
    return (try lowerMode(self, id, iteration, .reference, null)).?;
}

pub fn lowerValue(self: *Lower, id: ir.ExprId, iteration: ir.Iteration) Lower.Error!node.ExpressionId {
    return (try lowerMode(self, id, iteration, .value, null)).?;
}

pub fn discard(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const value = self.program.expression(id).value;

    if (value != .iteration) return self.expr(id);

    return (try lowerMode(self, id, value.iteration, .discard, null)).?;
}

pub fn consume(self: *Lower, id: ir.ExprId, consumer: Consumer) Lower.Error!?node.ExpressionId {
    return lowerMode(self, id, self.program.expression(id).value.iteration, .consume, consumer);
}

fn lowerMode(self: *Lower, id: ir.ExprId, iteration: ir.Iteration, mode: result.Mode, consumer: ?Consumer) Lower.Error!?node.ExpressionId {
    var frame = Frame.create(self, id, iteration, mode, consumer);

    defer frame.restore();

    if (!generated) return runSeed(&frame);

    const entry = @import("generated_lower_loop");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .loop_frame = @ptrCast(&frame),
        .id = @backingInt(id),
        .initial = @backingInt(iteration.initial),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const value = try entry.executeIn(empty.allocator(), &input);

    return if (value) |expression| @fromBackingInt(expression) else null;
}

fn runSeed(frame: *Frame) Lower.Error!?node.ExpressionId {
    const self = frame.lowering;
    const handle: *const anyopaque = @ptrCast(frame);
    const operand = frame.iteration.initial;

    switch (try prepare.beginLoweredLoop(handle)) {
        .Reject => return null,
        .Dereference => return @fromBackingInt(try prepare.dereferenceLoweredLoop(self, @backingInt(try lower(self, frame.id, frame.iteration)))),
        .Proceed => {},
    }

    const route = prepare.prepareLoopInitial(handle);

    if (route == .Deep) prepare.setLoopInitialScope(handle, true);

    const value = if (route == .Value) try @import("value_call/root.zig").expression(self, operand) else try self.expr(operand);

    if (route == .Deep) prepare.setLoopInitialScope(handle, false);
    try prepare.saveLoopInitial(handle, @backingInt(value));
    try prepare.prepareLoopState(handle);
    try prepare.openLoopParameters(handle);
    try prepare.prepareLoopUpdate(handle);

    const projected = frame.fields != null;

    if (projected) try emit.declareLoopState(handle);

    const first = try emit.lowerLoopFirstTest(handle);
    const operands = emit.enterLoopUpdate(handle);
    const condition = try self.expr(@fromBackingInt(operands.condition));
    const body: ir.ExprId = @fromBackingInt(operands.body);
    const update = if (operands.by_value) try @import("value_call/root.zig").expression(self, body) else try self.expr(body);

    emit.saveLoopUpdate(handle, @backingInt(condition), @backingInt(update), first);

    if (!projected) try emit.declareLoopState(handle);
    try emit.enterLoweredLoop(handle);
    try emit.writeLoopUpdate(handle);
    try emit.frameLoweredLoop(handle);
    try emit.recoverLoweredLoop(handle);

    return @fromBackingInt(try emit.finishLoweredLoop(handle));
}
