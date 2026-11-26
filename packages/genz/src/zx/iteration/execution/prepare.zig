const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const Context = @import("../../iteration_value/root.zig");
const aggregate = @import("../../aggregate.zig");
const selection = @import("../../iteration_layout/select.zig");
const seed_parameters = @import("../parameters_seed.zig");
const initial = @import("../initial.zig");
const scope = @import("../../state_value/scope.zig");
const step = @import("../step.zig");
const generated = @import("genz_options").generated_analysis;
const Api = @import("../../expressions/evaluate.zig").Api;
const Admission = if (generated) Api.LoopAdmission else enum { Proceed, Dereference, Reject };
const Error = Lower.Error;

pub fn beginLoweredLoop(handle: *anyopaque) Error!Admission {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const projected = if (frame.consumer) |selected| try @import("../../iteration_value/result.zig").candidate(self.allocator, self.program, selected) else false;
    frame.name = try self.fresh("state");
    frame.state = try self.builder.identifier(frame.name);
    frame.selection = try selection.choose(self, frame.id, frame.iteration, frame.mode, frame.consumer, projected);

    if (frame.selection.representation != .dereference and frame.selection.representation != .reject) {
        frame.type_id = @fromBackingInt(self.program.expressions.types[@backingInt(frame.id)]);

        frame.initial = if (generated) frame.selection.plan else initial.plan(.{
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

        frame.state_info = .{
            .name = frame.name,
            .forwarded = if (frame.selection.forwarded) |call| @backingInt(call) else null,
        };
    }

    return switch (frame.selection.representation) {
        .dereference => .Dereference,
        .reject => .Reject,
        else => .Proceed,
    };
}

pub fn setLoopInitialScope(handle: *anyopaque, active: bool) void {
    const frame = Frame.borrow(handle);

    if (active) {
        frame.initial_scope = scope.enter(frame.lowering, .Iteration, .{ .iteration_value = &frame.context });
    } else {
        frame.initial_scope.?.restore();

        frame.initial_scope = null;
    }
}

pub fn saveLoopInitial(handle: *anyopaque, value: u32) Error!void {
    const frame = Frame.borrow(handle);

    frame.initial_value = if (frame.initial.local) try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(value)) else @fromBackingInt(value);

    if (frame.initial.guard != .None) try guardLoopInitial(handle, @backingInt(frame.initial_value));
}

pub fn guardLoopInitial(handle: *anyopaque, value: u32) Error!void {
    const frame = Frame.borrow(handle);
    const guard = try @import("../../iteration_value/initial.zig").create(frame.lowering, &frame.body, frame.iteration, frame.consumer, @fromBackingInt(value), frame.initial.guard);

    frame.guard = guard;

    frame.guard_info = .{
        .body = @import("../../construction/publication.zig").packSpan(guard.body),
        .condition = @backingInt(guard.condition),
        .fallback = @backingInt(guard.result),
    };
}

pub fn prepareLoopState(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    if (frame.initial.state_scope) try enterLoopRepresentation(handle);

    _ = try createLoopSeed(handle);

    if (frame.initial.project_fields) _ = try prepareLoopFields(handle);
    if (frame.initial.track) try trackLoopChange(handle);
}

pub fn enterLoopRepresentation(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.representation = try @import("../../state_value/root.zig").enter(frame.lowering);
}

fn createLoopSeed(handle: *anyopaque) Error![]const u8 {
    const frame = Frame.borrow(handle);
    const lowering = frame.lowering;
    const name = try lowering.fresh("loop_seed");
    frame.seed = try lowering.builder.identifier(name);

    return name;
}

pub fn prepareLoopFields(handle: *anyopaque) Error!bool {
    const frame = Frame.borrow(handle);
    frame.fields = try @import("../fields/prepare.zig").prepare(frame.lowering, frame.iteration, frame.type_id, &frame.body, frame.seed);

    return frame.fields != null;
}

fn trackLoopChange(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.changed_name = try frame.lowering.fresh("state_changed");
}

pub fn openLoopParameters(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.parameters = try seed_parameters.enter(frame.lowering, frame.iteration, frame.initial.parameters, frame.name, &frame.context);
}

pub fn addLoopParameterMembers(handle: *anyopaque, condition: bool, step_parameter: bool) Error!void {
    const frame = Frame.borrow(handle);
    const lowering = frame.lowering;

    const symbols = switch (frame.initial.parameters) {
        .Plain => unreachable,
        .State => &lowering.state_symbols,
        .Stack => &lowering.stack_symbols,
        .Deep => &frame.context.symbols,
    };

    const ids = [_]ir.SymbolId{ frame.iteration.condition_parameter, frame.iteration.parameter };
    const first = @intFromBool(!condition);
    const end = ids.len - @intFromBool(!step_parameter);

    try symbols.addMany(lowering.allocator, ids[first..end]);
}

pub fn openLoopParameterContext(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);
    frame.parameters.context = scope.enter(frame.lowering, .Iteration, .{ .iteration_value = &frame.context });
}

pub fn prepareLoopUpdate(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const initial_value = @backingInt(frame.initial_value);

    const value = switch (frame.initial.storage) {
        .Keep => initial_value,
        .Dereference => @backingInt(try @import("../../access/emit.zig").dereference(frame.lowering, frame.initial_value)),
        .Deep => try deepenLoopInitial(handle, initial_value),
        .State => try representLoopInitial(handle, initial_value, false),
        .StateValue => try representLoopInitial(handle, initial_value, true),
        .Clip => try clipLoopInitial(handle, initial_value),
    };

    frame.initial_state = @fromBackingInt(value);

    frame.schedule = step.plan(.{
        .condition = @backingInt(frame.iteration.condition),
        .body = @backingInt(frame.iteration.body),
        .forwarded = if (frame.selection.forwarded) |call| @backingInt(call) else null,
        .postcondition = frame.iteration.postcondition,
        .projected = frame.fields != null,
        .selected_state = frame.initial.selected_state,
        .layout = frame.initial.layout,
        .discard = frame.mode == .discard,
    });
}

pub fn deepenLoopInitial(handle: *anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../iteration_value/conversion.zig").convert(&frame.context, frame.type_id, @fromBackingInt(value), false));
}

pub fn representLoopInitial(handle: *anyopaque, value: u32, by_value: bool) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../state_value/conversion.zig").convert(frame.lowering, &frame.body, frame.type_id, @fromBackingInt(value), if (by_value) .value_layout else .value));
}

pub fn clipLoopInitial(handle: *anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../state_value/ownership.zig").clip(frame.lowering, &frame.body, frame.iteration.initial, @fromBackingInt(value)));
}

pub fn releaseLoopPlanningScratch(handle: *anyopaque) void {
    _ = Frame.borrow(handle).renewal_workspace.scratch.reset(.free_all);
}
