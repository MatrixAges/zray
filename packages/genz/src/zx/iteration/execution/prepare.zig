const std = @import("std");
const ir = @import("zx").ir;
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
const Admission = if (generated) @FieldType(std.meta.Child(@import("generated_lower_loop").Input), "admission") else enum { Proceed, Dereference, Reject };
const Error = Lower.Error;

pub fn beginLoweredLoop(frame: *Frame) Error!Admission {
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
            .reference = @backingInt(frame.state),
            .forwarded = if (frame.selection.forwarded) |call| @backingInt(call) else null,
        };
    }

    return switch (frame.selection.representation) {
        .dereference => .Dereference,
        .reject => .Reject,
        else => .Proceed,
    };
}

pub fn setLoopInitialScope(frame: *Frame, active: bool) void {
    if (active) {
        frame.initial_scope = scope.enter(frame.lowering, .Iteration, .{ .iteration_value = &frame.context });
    } else {
        frame.initial_scope.?.restore();

        frame.initial_scope = null;
    }
}

pub fn saveLoopInitial(frame: *Frame, value: u32) Error!void {
    frame.initial_value = if (frame.initial.local) try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(value)) else @fromBackingInt(value);

    if (frame.initial.guard != .None) {
        frame.guard = try @import("../../iteration_value/initial.zig").create(
            frame.lowering,
            &frame.body,
            frame.iteration,
            frame.consumer,
            frame.initial_value,
            frame.initial.guard,
        );
    }
}

pub fn prepareLoopState(frame: *Frame) Error!void {
    if (frame.initial.state_scope) try enterLoopRepresentation(frame);

    _ = try createLoopSeed(frame);

    if (frame.initial.project_fields) try prepareLoopFieldsFrame(frame);
    if (frame.initial.track) frame.changed_name = try frame.lowering.fresh("state_changed");
}

pub fn enterLoopRepresentation(frame: *Frame) Error!void {
    frame.representation = try @import("../../state_value/root.zig").enter(frame.lowering);
}

fn createLoopSeed(frame: *Frame) Error![]const u8 {
    const lowering = frame.lowering;
    const name = try lowering.fresh("loop_seed");
    frame.seed = try lowering.builder.identifier(name);

    return name;
}

const LoopProjection = @import("../../expressions/evaluate.zig").Api.LoopProjection;

pub fn prepareLoopFields(handle: *anyopaque) Error!?*const LoopProjection {
    const frame = @import("../../expressions/evaluate.zig").borrow(handle).loop.?;

    try prepareLoopFieldsFrame(frame);

    const fields = if (frame.fields) |*value| value else return null;

    frame.projection = .{ .borrowed = fields.borrowed, .layout = @backingInt(fields.layout) };

    return &frame.projection;
}

fn prepareLoopFieldsFrame(frame: *Frame) Error!void {
    frame.fields = try @import("../fields/prepare.zig").prepare(frame.lowering, frame.iteration, frame.type_id, &frame.body, frame.seed);
}

pub fn openLoopParameters(frame: *Frame) Error!void {
    frame.parameters = try seed_parameters.enter(frame.lowering, frame.iteration, frame.initial.parameters, frame.name, &frame.context);
}

pub fn addLoopParameterMembers(frame: *Frame, condition: bool, step_parameter: bool) Error!void {
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

pub fn openLoopParameterContext(frame: *Frame) void {
    frame.parameters.context = scope.enter(frame.lowering, .Iteration, .{ .iteration_value = &frame.context });
}

pub fn prepareLoopUpdate(frame: *Frame) Error!void {
    const initial_value = @backingInt(frame.initial_value);

    const value = switch (frame.initial.storage) {
        .Keep => initial_value,
        .Dereference => @backingInt(try @import("../../access/emit.zig").dereference(frame.lowering, frame.initial_value)),
        .Deep => @backingInt(try @import("../../iteration_value/conversion.zig").convert(&frame.context, frame.type_id, frame.initial_value, false)),
        .State, .StateValue => @backingInt(try @import("../../state_value/conversion.zig").convert(frame.lowering, &frame.body, frame.type_id, frame.initial_value, if (frame.initial.storage == .StateValue) .value_layout else .value)),
        .Clip => @backingInt(try @import("../../state_value/ownership.zig").clip(frame.lowering, &frame.body, frame.iteration.initial, frame.initial_value)),
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
