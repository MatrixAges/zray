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

fn Store(comptime field: []const u8) type {
    return std.meta.Child(@FieldType(entry.zx_pending, field));
}

const StoreValues = if (generated) struct {
    store_0: Store("store_0") = &.{ .active = false },
    store_1: Store("store_1") = &.{ .active = false },
    store_2: Store("store_2") = &.{ .has_seed = false, .seed = 0, .changed_name = null },
    store_3: Store("store_3") = &.{
        .name = &.{},
        .active = false,
        .add_condition = false,
        .add_step = false,
        .previous_condition = &.{},
        .previous_step = &.{},
        .remove_state_condition = false,
        .remove_state_step = false,
        .remove_stack_condition = false,
        .remove_stack_step = false,
    },
    store_4: Store("store_4") = &.{ .name = null },
    store_5: Store("store_5") = &.{ .projected = null, .delayed = false },
} else void;

const StoreHost = if (generated) struct {
    frame: *Frame,
    store_0: *Store("store_0"),
    store_1: *Store("store_1"),
    store_2: *Store("store_2"),
    store_3: *Store("store_3"),
    store_4: *Store("store_4"),
    store_5: *Store("store_5"),
    pub fn commit(self: *@This(), pending: anytype) Lower.Error!void {
        const frame = self.frame;

        if (pending.store_0) |next| {
            prepare.setLoopInitialScope(frame, next.active);

            self.store_0.* = next;
        }

        if (pending.store_1) |next| {
            try prepare.enterLoopRepresentation(frame);

            self.store_1.* = next;
        }

        if (pending.store_2) |next| {
            if (next.has_seed) frame.seed = @fromBackingInt(next.seed);

            self.store_2.* = next;
        }

        if (pending.store_3) |next| {
            frame.parameters.flags = .{
                next.active,
                next.remove_state_condition,
                next.remove_state_step,
                next.remove_stack_condition,
                next.remove_stack_step,
            };

            frame.parameters.previous = .{ next.previous_condition, next.previous_step };

            self.rename(next.name);

            if (frame.initial.parameters != .Plain) {
                try prepare.addLoopParameterMembers(frame, next.add_condition, next.add_step);
            }

            if (frame.initial.parameters == .Deep) prepare.openLoopParameterContext(frame);

            self.store_3.* = next;
        }

        if (pending.store_4) |next| {
            if (next.name) |name| self.rename(name);

            self.store_4.* = next;
        }

        if (pending.store_5) |next| {
            if (next.projected) |projected| {
                emit.enterLoopUpdate(frame, if (projected) .Projected else .Ordinary, next.delayed);
            } else {
                frame.restoreUpdate();
            }

            self.store_5.* = next;
        }
    }
    fn rename(self: @This(), name: []const u8) void {
        const frame = self.frame;
        const names = frame.lowering.names;

        names[@backingInt(frame.iteration.condition_parameter)] = name;
        names[@backingInt(frame.iteration.parameter)] = name;
    }
} else void;

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
    const admission = try prepare.beginLoweredLoop(frame);
    const state = self.state_symbols.current();
    const stack = self.stack_symbols.current();

    const state_view: Index = .{
        .keys = state.keys.items,
        .buckets = state.buckets.items,
    };

    const stack_view: Index = .{
        .keys = stack.keys.items,
        .buckets = stack.buckets.items,
    };

    const parameters: Views = .{
        .condition = @backingInt(frame.iteration.condition_parameter),
        .step = @backingInt(frame.iteration.parameter),
        .names = self.names,
        .state = &state_view,
        .stack = &stack_view,
    };

    comptime std.debug.assert(@typeInfo(node.ExpressionId).@"enum".tag_type == u32);

    var stores: StoreValues = .{};

    var host: StoreHost = .{
        .frame = frame,
        .store_0 = &stores.store_0,
        .store_1 = &stores.store_1,
        .store_2 = &stores.store_2,
        .store_3 = &stores.store_3,
        .store_4 = &stores.store_4,
        .store_5 = &stores.store_5,
    };

    const Facts = std.meta.Child(@FieldType(Input, "assignment_facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const facts: Facts = .{ .types = &types, .selected = self.state_plan.selected };

    const input: Input = .{
        .admission = admission,
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body_seq = @ptrCast(&frame.body),
        .loop_seq = @ptrCast(&frame.loop),
        .projected_seq = @ptrCast(&frame.projected_body),
        .skipped_seq = @ptrCast(&frame.skipped_body),
        .wrap_seq = @ptrCast(&frame.wrap_body),
        .consumer = if (frame.consumer) |consumer| &.{
            .symbol = @backingInt(consumer.symbol),
            .result = @backingInt(consumer.result),
            .layout = consumer.layout,
        } else null,
        .loop_frame = @ptrCast(frame),
        .context = @ptrCast(&frame.context),
        .assignment_facts = &facts,
        .state_active = self.state_active,
        .loop_state = &frame.state_info,
        .guard_info = &frame.guard_info,
        .id = @backingInt(frame.id),
        .type_id = self.program.expressions.types[@backingInt(frame.id)],
        .initial = @backingInt(frame.iteration.initial),
        .parameters = &parameters,
        .initial_plan = &frame.initial,
        .condition = @backingInt(frame.iteration.condition),
        .body = @backingInt(frame.iteration.body),
        .postcondition = frame.iteration.postcondition,
        .discard = frame.mode == .discard,
        .renewal_source = renewal_source,
    };

    const output = entry.executeIn(temporary, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return if (output.expression) |expression| @fromBackingInt(expression) else null;
}

fn runSeed(frame: *Frame) Lower.Error!?node.ExpressionId {
    const self = frame.lowering;
    const handle: *anyopaque = @ptrCast(frame);
    const operand = frame.iteration.initial;

    switch (try prepare.beginLoweredLoop(frame)) {
        .Reject => return null,
        .Dereference => return try self.builder.expression(.{ .dereference = try lower(self, frame.id, frame.iteration) }),
        .Proceed => {},
    }

    const route = frame.initial.evaluation;

    if (route == .Deep) prepare.setLoopInitialScope(frame, true);

    const value = if (route == .Value) try @import("value_call/root.zig").expression(self, operand) else try self.expr(operand);

    if (route == .Deep) prepare.setLoopInitialScope(frame, false);
    try prepare.saveLoopInitial(handle, @backingInt(value));
    try prepare.prepareLoopState(handle);
    try prepare.openLoopParameters(handle);
    try prepare.prepareLoopUpdate(handle);

    const projected = frame.fields != null;

    if (projected) {
        const mutable = @import("iteration/renewal_seed.zig").needsEntries(self, frame.id);

        try emit.declareSeedState(handle, .State, true, mutable, @backingInt(frame.initial_state));
    }

    const first = try emit.lowerLoopFirstTest(handle);

    emit.enterLoopUpdate(frame, if (projected) .Projected else .Ordinary, false);

    const condition = try self.expr(@fromBackingInt(frame.schedule.condition));
    const body: ir.ExprId = @fromBackingInt(frame.schedule.step);
    const update = if (frame.schedule.by_value) try @import("value_call/root.zig").expression(self, body) else try self.expr(body);

    frame.restoreUpdate();

    frame.next = .{
        .condition = condition,
        .value = update,
        .first = if (first) |id| @fromBackingInt(id) else null,
    };

    if (!projected) try emit.declareSeedState(handle, frame.initial.parameters, false, true, @backingInt(frame.initial_state));

    const prefix = try emit.enterLoweredLoop(handle);
    const written = try emit.writeLoopUpdate(handle);

    const span = try @import("iteration/frame.zig").lower(self, if (projected) .{} else prefix.growth, written, .{
        .condition = frame.next.condition,
        .after_step = frame.schedule.after_step,
        .guarded_initial = !projected and frame.guard != null,
    });

    const recovered = try emit.recoverLoweredLoop(handle);

    return @fromBackingInt(try emit.finishLoweredLoop(handle, recovered, .{
        .renewals = if (projected) prefix.growth else .{},
        .declarations = prefix.declarations,
        .frame = span,
    }));
}
