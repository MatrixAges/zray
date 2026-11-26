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
const entry = if (generated) @import("generated_lower_loop") else struct {};
const Input = if (generated) std.meta.Child(entry.Input) else void;
const RenewalSource = if (generated) std.meta.Child(std.meta.Child(@FieldType(Input, "renewal_source"))) else void;

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

    defer frame.release();

    return run(&frame);
}

fn run(frame: *Frame) Lower.Error!?node.ExpressionId {
    if (frame.lowering.plan.renewals.keys.len != 0) return runWithRenewals(frame);

    var scratch = std.heap.ArenaAllocator.init(frame.lowering.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    return execute(frame, memory.allocator(), null);
}

fn runWithRenewals(frame: *Frame) Lower.Error!?node.ExpressionId {
    const roots = [_]u32{ @backingInt(frame.iteration.condition), @backingInt(frame.iteration.body) };

    return @import("growth/renew_workspace.zig").run(frame, RenewalSource, .{
        .type_id = @fromBackingInt(frame.lowering.program.expressions.types[@backingInt(frame.id)]),
        .roots = &roots,
    }, execute);
}

fn execute(frame: *Frame, temporary: std.mem.Allocator, renewal_source: ?*const RenewalSource) Lower.Error!?node.ExpressionId {
    const Views = std.meta.Child(@FieldType(Input, "parameters"));
    const Index = std.meta.Child(@FieldType(Views, "state"));
    const self = frame.lowering;
    const state = self.state_symbols.current();
    const stack = self.stack_symbols.current();
    var state_count: []u64 = @as(*[1]u64, @ptrCast(&state.count));
    var stack_count: []u64 = @as(*[1]u64, @ptrCast(&stack.count));
    var flags: []bool = &frame.parameters.flags;
    var previous: [][]const u8 = &frame.parameters.previous;
    const initial_plan: *const @TypeOf(frame.initial) = &frame.initial;
    var origin: @import("construction/publication.zig").OriginBuffer = .{};

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

    comptime std.debug.assert(@typeInfo(node.ExpressionId).@"enum".tag_type == u32);

    var seed_slot: []u32 = @as(*[1]u32, @ptrCast(&frame.seed));
    var changed_slot: [][]const u8 = @as(*[1][]const u8, @ptrCast(&frame.changed_name));
    const state_info: *const Frame.StateInfo = &frame.state_info;
    const guard_info: *const Frame.GuardInfo = &frame.guard_info;

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .body_seq = @ptrCast(&frame.body),
        .loop_frame = @ptrCast(frame),
        .loop_state = zx.columns.pointer(@FieldType(Input, "loop_state"), state_info),
        .guard_info = zx.columns.pointer(@FieldType(Input, "guard_info"), guard_info),
        .seed_slot = @ptrCast(&seed_slot),
        .changed_slot = @ptrCast(&changed_slot),
        .id = @backingInt(frame.id),
        .initial = @backingInt(frame.iteration.initial),
        .parameters = &parameters,
        .initial_plan = zx.columns.pointer(@FieldType(Input, "initial_plan"), initial_plan),
        .condition = @backingInt(frame.iteration.condition),
        .body = @backingInt(frame.iteration.body),
        .postcondition = frame.iteration.postcondition,
        .discard = frame.mode == .discard,
        .renewal_source = renewal_source,
    };

    const output = entry.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return if (output.expression) |expression| @fromBackingInt(expression) else null;
}

fn runSeed(frame: *Frame) Lower.Error!?node.ExpressionId {
    const self = frame.lowering;
    const handle: *anyopaque = @ptrCast(frame);
    const operand = frame.iteration.initial;

    switch (try prepare.beginLoweredLoop(handle)) {
        .Reject => return null,
        .Dereference => return try self.builder.expression(.{ .dereference = try lower(self, frame.id, frame.iteration) }),
        .Proceed => {},
    }

    const route = frame.initial.evaluation;

    if (route == .Deep) prepare.setLoopInitialScope(handle, true);

    const value = if (route == .Value) try @import("value_call/root.zig").expression(self, operand) else try self.expr(operand);

    if (route == .Deep) prepare.setLoopInitialScope(handle, false);
    try prepare.saveLoopInitial(handle, @backingInt(value));
    try prepare.prepareLoopState(handle);
    try prepare.openLoopParameters(handle);
    try prepare.prepareLoopUpdate(handle);

    const projected = frame.fields != null;

    if (projected) {
        const mutable = @import("iteration/renewal_seed.zig").needsEntries(self, frame.id);

        try emit.declareLoopState(handle, .State, true, mutable, @backingInt(frame.initial_state));
    }

    const first = try emit.lowerLoopFirstTest(handle);

    emit.enterLoopUpdate(handle, if (projected) .Projected else .Ordinary, false);

    const condition = try self.expr(@fromBackingInt(frame.schedule.condition));
    const body: ir.ExprId = @fromBackingInt(frame.schedule.step);
    const update = if (frame.schedule.by_value) try @import("value_call/root.zig").expression(self, body) else try self.expr(body);

    frame.restoreUpdate();

    frame.next = .{
        .condition = condition,
        .value = update,
        .first = if (first) |id| @fromBackingInt(id) else null,
    };

    if (!projected) try emit.declareLoopState(handle, frame.initial.parameters, false, true, @backingInt(frame.initial_state));
    try emit.enterLoweredLoop(handle);
    try emit.writeLoopUpdate(handle);
    try emit.frameLoweredLoop(handle, @backingInt(frame.next.condition), frame.schedule.after_step);
    try emit.recoverLoweredLoop(handle);

    return @fromBackingInt(try emit.finishLoweredLoop(handle));
}
