const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const Context = @import("../../iteration_value/root.zig");
const aggregate = @import("../../aggregate.zig");
const selection = @import("../../iteration_layout/select.zig");
const parameters = @import("../parameters.zig");
const initial = @import("../initial.zig");
const scope = @import("../../state_value/scope.zig");
const step = @import("../step.zig");
const renewal = @import("../renewal.zig");
const generated = @import("genz_options").generated_analysis;
const Api = @import("../../expressions/evaluate.zig").Api;
const Admission = if (generated) Api.LoopAdmission else enum { Proceed, Dereference, Reject };
const Initial = if (generated) Api.LoopInitial else @FieldType(initial.Plan, "evaluation");
const Error = Lower.Error;

pub fn beginLoweredLoop(handle: *const anyopaque) Error!Admission {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const projected = if (frame.consumer) |selected| try @import("../../iteration_value/result.zig").candidate(self.allocator, self.program, selected) else false;
    frame.name = try self.fresh("state");
    frame.state = try self.builder.identifier(frame.name);
    frame.selection = try selection.choose(self, frame.id, frame.iteration, frame.mode, frame.consumer, projected);

    return switch (frame.selection.representation) {
        .dereference => .Dereference,
        .reject => .Reject,
        else => .Proceed,
    };
}

pub fn dereferenceLoweredLoop(handle: *const anyopaque, value: u32) Error!u32 {
    const self: *Lower = @ptrCast(@alignCast(@constCast(handle)));

    return @backingInt(try self.builder.expression(.{ .dereference = @fromBackingInt(value) }));
}

pub fn prepareLoopInitial(handle: *const anyopaque) Initial {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.type_id = @fromBackingInt(self.program.expressions.types[@backingInt(frame.id)]);

    frame.initial = initial.plan(.{
        .representation = frame.selection.representation,
        .mode = frame.mode,
        .state_active = self.state_active,
        .direct_initial = frame.selection.direct_initial,
        .postcondition = frame.iteration.postcondition,
        .consumer = frame.consumer != null,
        .pure = frame.selection.pure,
        .forwarded = frame.selection.forwarded != null,
    });

    frame.context = .{ .lowering = self, .declarations = &frame.body, .inline_lists = frame.initial.buffered };

    return zx.columns.view(Initial, frame.initial.evaluation);
}

pub fn setLoopInitialScope(handle: *const anyopaque, active: bool) void {
    const frame = Frame.borrow(handle);

    if (active) {
        frame.initial_scope = scope.enter(frame.lowering, .Iteration, .{ .iteration_value = &frame.context });
    } else {
        frame.initial_scope.?.restore();

        frame.initial_scope = null;
    }
}

pub fn saveLoopInitial(handle: *const anyopaque, value: u32) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const expression: node.ExpressionId = @fromBackingInt(value);

    frame.initial_value = if (frame.initial.local) try aggregate.bind(self, &frame.body, expression) else expression;

    if (frame.initial.guard != .None) {
        frame.guard = try @import("../../iteration_value/initial.zig").create(self, &frame.body, frame.iteration, frame.consumer, frame.initial_value, frame.initial.guard);
    }
}

pub fn prepareLoopState(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    if (frame.initial.state_scope) frame.representation = try @import("../../state_value/root.zig").enter(self);

    frame.seed = try self.builder.identifier(try self.fresh("loop_seed"));

    if (frame.initial.project_fields) frame.fields = try @import("../fields/prepare.zig").prepare(self, frame.iteration, frame.type_id, &frame.body, frame.seed);

    frame.changed_name = if (frame.initial.track) try self.fresh("state_changed") else "";
}

pub fn openLoopParameters(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.parameters = try parameters.enter(frame.lowering, frame.iteration, frame.initial.parameters, frame.name, &frame.context);
}

pub fn prepareLoopUpdate(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const value = frame.initial_value;

    frame.initial_state = switch (frame.initial.storage) {
        .Keep => value,
        .Dereference => try @import("../../access/emit.zig").dereference(self, value),
        .Deep => try @import("../../iteration_value/conversion.zig").convert(&frame.context, frame.type_id, value, false),
        .State, .StateValue => try @import("../../state_value/conversion.zig").convert(self, &frame.body, frame.type_id, value, if (frame.initial.storage == .StateValue) .value_layout else .value),
        .Clip => try @import("../../state_value/ownership.zig").clip(self, &frame.body, frame.iteration.initial, value),
    };

    frame.schedule = step.plan(.{
        .condition = @backingInt(frame.iteration.condition),
        .body = @backingInt(frame.iteration.body),
        .forwarded = if (frame.selection.forwarded) |call| @backingInt(call) else null,
        .postcondition = frame.iteration.postcondition,
        .projected = frame.fields != null,
        .selected_state = frame.initial.selected_state,
        .layout = frame.initial.layout,
        .buffered = frame.initial.buffered,
        .discard = frame.mode == .discard,
    });

    var memory = std.heap.BufferFirstAllocator.init(&frame.renewal_buffer, frame.renewal_arena.allocator());

    frame.renewals = try renewal.plan(self, memory.allocator(), .{
        .owner = frame.id,
        .type_id = frame.type_id,
        .classify = if (frame.schedule.classify_renewals) frame.iteration else null,
        .inline_lists = frame.schedule.inline_lists,
    });
}
