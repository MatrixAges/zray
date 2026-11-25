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
const Initial = if (generated) Api.LoopInitial else @FieldType(initial.Plan, "evaluation");
const Error = Lower.Error;

pub fn beginLoweredLoop(handle: *anyopaque) Error!Admission {
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

pub fn dereferenceLoweredLoop(handle: *anyopaque, value: u32) Error!u32 {
    const self: *Lower = @ptrCast(@alignCast(handle));

    return @backingInt(try self.builder.expression(.{ .dereference = @fromBackingInt(value) }));
}

pub fn prepareLoopInitial(handle: *anyopaque) Initial {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

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

    return zx.columns.view(Initial, frame.initial.evaluation);
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
    storeLoopInitial(handle, if (loopBindsInitial(handle)) try bindLoopInitial(handle, value) else value);

    if (loopGuardsInitial(handle)) try guardLoopInitial(handle);
}

pub fn loopBindsInitial(handle: *anyopaque) bool {
    return Frame.borrow(handle).initial.local;
}

pub fn bindLoopInitial(handle: *anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(value)));
}

pub fn storeLoopInitial(handle: *anyopaque, value: u32) void {
    Frame.borrow(handle).initial_value = @fromBackingInt(value);
}

pub fn loopGuardsInitial(handle: *anyopaque) bool {
    return Frame.borrow(handle).initial.guard != .None;
}

pub fn guardLoopInitial(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.guard = try @import("../../iteration_value/initial.zig").create(frame.lowering, &frame.body, frame.iteration, frame.consumer, frame.initial_value, frame.initial.guard);
}

pub fn prepareLoopState(handle: *anyopaque) Error!void {
    if (loopUsesStateScope(handle)) try enterLoopRepresentation(handle);

    try createLoopSeed(handle);
    if (loopProjectsFields(handle)) try prepareLoopFields(handle);
    if (loopTracksChange(handle)) try trackLoopChange(handle);
}

pub fn loopUsesStateScope(handle: *anyopaque) bool {
    return Frame.borrow(handle).initial.state_scope;
}

pub fn enterLoopRepresentation(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.representation = try @import("../../state_value/root.zig").enter(frame.lowering);
}

pub fn createLoopSeed(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const lowering = frame.lowering;

    frame.seed = try lowering.builder.identifier(try lowering.fresh("loop_seed"));
}

pub fn loopProjectsFields(handle: *anyopaque) bool {
    return Frame.borrow(handle).initial.project_fields;
}

pub fn prepareLoopFields(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.fields = try @import("../fields/prepare.zig").prepare(frame.lowering, frame.iteration, frame.type_id, &frame.body, frame.seed);
}

pub fn loopTracksChange(handle: *anyopaque) bool {
    return Frame.borrow(handle).initial.track;
}

pub fn trackLoopChange(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.changed_name = try frame.lowering.fresh("state_changed");
}

pub fn openLoopParameters(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.parameters = try seed_parameters.enter(frame.lowering, frame.iteration, frame.initial.parameters, frame.name, &frame.context);
}

pub fn loopParameterLayout(handle: *anyopaque) Api.LoopParameterLayout {
    return zx.columns.view(Api.LoopParameterLayout, Frame.borrow(handle).initial.parameters);
}

pub fn loopParameterName(handle: *anyopaque) []const u8 {
    return Frame.borrow(handle).name;
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
    const value = switch (Frame.borrow(handle).initial.storage) {
        .Keep => loopInitialValue(handle),
        .Dereference => try dereferenceLoopInitial(handle),
        .Deep => try deepenLoopInitial(handle),
        .State => try representLoopInitial(handle, false),
        .StateValue => try representLoopInitial(handle, true),
        .Clip => try clipLoopInitial(handle),
    };

    storeLoopPreparedState(handle, value);

    const frame = Frame.borrow(handle);

    frame.schedule = step.plan(.{
        .condition = @backingInt(frame.iteration.condition),
        .body = @backingInt(frame.iteration.body),
        .forwarded = loopForwardedCall(handle),
        .postcondition = frame.iteration.postcondition,
        .projected = frame.fields != null,
        .selected_state = frame.initial.selected_state,
        .layout = frame.initial.layout,
        .discard = frame.mode == .discard,
    });
}

pub fn loopStorage(handle: *anyopaque) Api.LoopStorage {
    return zx.columns.view(Api.LoopStorage, Frame.borrow(handle).initial.storage);
}

pub fn loopInitialValue(handle: *anyopaque) u32 {
    return @backingInt(Frame.borrow(handle).initial_value);
}

pub fn dereferenceLoopInitial(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../access/emit.zig").dereference(frame.lowering, frame.initial_value));
}

pub fn deepenLoopInitial(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../iteration_value/conversion.zig").convert(&frame.context, frame.type_id, frame.initial_value, false));
}

pub fn representLoopInitial(handle: *anyopaque, by_value: bool) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../state_value/conversion.zig").convert(frame.lowering, &frame.body, frame.type_id, frame.initial_value, if (by_value) .value_layout else .value));
}

pub fn clipLoopInitial(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../state_value/ownership.zig").clip(frame.lowering, &frame.body, frame.iteration.initial, frame.initial_value));
}

pub fn storeLoopPreparedState(handle: *anyopaque, value: u32) void {
    Frame.borrow(handle).initial_state = @fromBackingInt(value);
}

pub fn loopForwardedCall(handle: *anyopaque) ?u32 {
    const frame = Frame.borrow(handle);

    return if (frame.selection.forwarded) |call| @backingInt(call) else null;
}

pub fn releaseLoopPlanningScratch(handle: *anyopaque) void {
    _ = Frame.borrow(handle).renewal_workspace.scratch.reset(.free_all);
}
