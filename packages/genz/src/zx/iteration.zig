const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
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

    if (!generated) {
        defer frame.restoreSeed();

        return runSeed(&frame);
    }

    return run(&frame);
}

fn run(frame: *Frame) Lower.Error!?node.ExpressionId {
    const entry = @import("generated_lower_loop");
    const release = @import("generated_release_loop");
    const Input = std.meta.Child(entry.Input);
    const Views = std.meta.Child(@FieldType(Input, "parameters"));
    const Index = std.meta.Child(@FieldType(Views, "state"));
    const self = frame.lowering;
    const state = self.state_symbols.current();
    const stack = self.stack_symbols.current();
    const state_count: []u64 = @as(*[1]u64, @ptrCast(&state.count));
    const stack_count: []u64 = @as(*[1]u64, @ptrCast(&stack.count));
    const flags: []bool = &frame.parameters.flags;
    const previous: [][]const u8 = &frame.parameters.previous;

    const state_view: Index = .{
        .count = @ptrCast(&state_count),
        .keys = @ptrCast(&state.keys.items),
        .buckets = @ptrCast(&state.buckets.items),
    };

    const stack_view: Index = .{
        .count = @ptrCast(&stack_count),
        .keys = @ptrCast(&stack.keys.items),
        .buckets = @ptrCast(&stack.buckets.items),
    };

    const parameters: Views = .{
        .condition = @backingInt(frame.iteration.condition_parameter),
        .step = @backingInt(frame.iteration.parameter),
        .target = @ptrCast(&self.names),
        .previous = @ptrCast(&previous),
        .flags = @ptrCast(&flags),
        .state = &state_view,
        .stack = &stack_view,
    };

    const input: Input = .{
        .frame = @ptrCast(self),
        .loop_frame = @ptrCast(frame),
        .id = @backingInt(frame.id),
        .initial = @backingInt(frame.iteration.initial),
        .parameters = &parameters,
        .operands = &frame.operands,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const resources: std.meta.Child(release.Input) = .{ .loop_frame = input.loop_frame, .parameters = &parameters };

    defer release.executeIn(empty.allocator(), &resources) catch unreachable;

    const value = entry.executeIn(empty.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

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

    if (projected) try emit.declareLoopState(handle, .State, true);

    const first = try emit.lowerLoopFirstTest(handle);

    emit.enterLoopUpdate(handle, if (projected) .Projected else .Ordinary);

    const operands = frame.operands;
    const condition = try self.expr(@fromBackingInt(operands.condition));
    const body: ir.ExprId = @fromBackingInt(operands.body);
    const update = if (operands.by_value) try @import("value_call/root.zig").expression(self, body) else try self.expr(body);

    frame.restoreUpdate();
    emit.saveLoopUpdate(handle, @backingInt(condition), @backingInt(update), first);

    if (!projected) try emit.declareLoopState(handle, frame.initial.parameters, false);
    try emit.enterLoweredLoop(handle);
    try emit.writeLoopUpdate(handle);
    try emit.frameLoweredLoop(handle);
    try emit.recoverLoweredLoop(handle);

    return @fromBackingInt(try emit.finishLoweredLoop(handle));
}
