const zx = @import("zx");
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const aggregate = @import("../../aggregate.zig");
const declarations = @import("../state.zig");
const step = @import("../step.zig");
const scope = @import("../../state_value/scope.zig");
const result = @import("../result.zig");
const generated = @import("genz_options").generated_analysis;
const Error = Lower.Error;
const Api = @import("../../expressions/evaluate.zig").Api;
const Layout = if (generated) Api.LoopParameterLayout else @import("../parameters_seed.zig").Layout;

pub fn loopProjects(handle: *const anyopaque) bool {
    return Frame.borrow(handle).fields != null;
}

pub fn lowerLoopFirstTest(handle: *const anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const condition = frame.schedule.first_test orelse return null;
    const parameters = &frame.parameters.?;

    parameters.rename(frame.lowering.builder.nodes.get(frame.seed).identifier);
    defer parameters.rename(frame.name);

    return @backingInt(try frame.lowering.expr(@fromBackingInt(condition)));
}

pub fn loopFirstCondition(handle: *const anyopaque) ?u32 {
    return Frame.borrow(handle).schedule.first_test;
}

pub fn loopSeedName(handle: *const anyopaque) []const u8 {
    const frame = Frame.borrow(handle);

    return frame.lowering.builder.nodes.get(frame.seed).identifier;
}

pub fn enterLoopUpdate(handle: *const anyopaque, update: Frame.UpdateScope) void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.step_scope = switch (update) {
        .Projected => .{ .Projected = scope.enter(self, .Projected, .{ .loop_fields = &frame.fields.? }) },
        .Ordinary => .{ .Ordinary = scope.enter(self, .Deferred, .{ .deferred_lists = frame.renewals.delayed }) },
        .None => unreachable,
    };
}

pub fn saveLoopUpdate(handle: *const anyopaque, condition: u32, value: u32, first: ?u32) void {
    const frame = Frame.borrow(handle);

    frame.next = .{
        .condition = @fromBackingInt(condition),
        .value = @fromBackingInt(value),
        .first = if (first) |id| @fromBackingInt(id) else null,
    };
}

pub fn declareLoopState(handle: *const anyopaque, form: Layout, projected: bool) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const type_id = frame.type_id;
    const name = if (projected) self.builder.nodes.get(frame.seed).identifier else frame.name;

    const layout = switch (form) {
        .Plain => try self.typeExpr(type_id),
        .Stack, .State => try self.layoutExpr(type_id),
        .Deep => try @import("../../iteration_value/types.zig").get(&frame.context, type_id),
    };

    frame.tracker = try declarations.declare(self, &frame.body, .{
        .name = name,
        .layout = layout,
        .initial = frame.initial_state,
        .mutable = !projected or frame.renewals.needsEntries(self),
        .tracking = if (frame.changed_name.len != 0) frame.changed_name else null,
    });
}

pub fn enterLoweredLoop(handle: *const anyopaque) Error!void {
    const projected = loopProjects(handle);

    try emitLoopRenewals(handle);

    if (projected) {
        try maskLoopBorrowedFields(handle);
        try declareProjectedLoopState(handle);
    }

    return publishLoopDeclarations(handle);
}

pub fn emitLoopRenewals(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.growth = try frame.renewals.store(frame.lowering, frame.type_id, .{
        .reference = if (frame.fields != null) frame.seed else frame.state,
    });
}

pub fn maskLoopBorrowedFields(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return frame.fields.?.maskBorrowed(frame.lowering, frame.output());
}

pub fn declareProjectedLoopState(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const fields = &frame.fields.?;
    const self = frame.lowering;

    _ = try declarations.declare(self, frame.output(), .{
        .name = frame.name,
        .layout = fields.layout,
        .initial = try fields.initial(self),
    });
}

pub fn publishLoopDeclarations(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const output = frame.output();

    frame.prefix.declarations = if (generated) try output.block(self.allocator) else try self.builder.statements(output.items);
}

pub fn writeLoopUpdate(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.update = try step.store(frame.lowering, &frame.loop, frame.schedule, .{
        .type_id = frame.type_id,
        .origin = frame.iteration.body,
        .target = frame.state,
        .value = frame.next.value,
        .fields = if (frame.fields) |*fields| fields else null,
    }, frame.tracker);
}

pub fn loopAssignment(handle: *const anyopaque) Api.LoopAssignment {
    return zx.columns.view(Api.LoopAssignment, Frame.borrow(handle).schedule.assignment);
}

pub fn loopNextValue(handle: *const anyopaque) u32 {
    return @backingInt(Frame.borrow(handle).next.value);
}

pub fn projectLoopAssignment(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.fields.?.qualify(frame.lowering, &frame.loop, frame.iteration.body, frame.next.value));
}

pub fn clipLoopAssignment(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../../state_value/ownership.zig").clip(frame.lowering, &frame.loop, frame.iteration.body, frame.next.value));
}

pub fn commitLoopUpdate(handle: *const anyopaque, value: u32) Error!void {
    const frame = Frame.borrow(handle);

    frame.update = try step.publish(frame.lowering, &frame.loop, .{
        .type_id = frame.type_id,
        .active = frame.schedule.assignment == .State and frame.lowering.state_active,
        .target = frame.state,
        .value = @fromBackingInt(value),
        .mark = if (frame.tracker) |flag| flag.generated else null,
    });
}

pub fn frameLoweredLoop(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const projected = frame.fields != null;

    frame.prefix.renewals = if (projected) frame.growth else .{};

    frame.prefix.frame = try @import("../frame.zig").lower(frame.lowering, if (projected) .{} else frame.growth, frame.update, .{
        .condition = frame.next.condition,
        .after_step = frame.schedule.after_step,
        .guarded_initial = !projected and frame.guard != null,
    });
}

pub fn recoverLoweredLoop(handle: *const anyopaque) Error!void {
    resetLoopResult(handle);

    if (loopRestoresFields(handle)) try restoreLoopFields(handle);
}

pub fn resetLoopResult(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.output().clearRetainingCapacity();

    frame.recovered = frame.state;
}

pub fn loopRestoresFields(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return frame.fields != null and frame.schedule.restore_projected;
}

pub fn restoreLoopFields(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.recovered = try aggregate.bind(self, frame.output(), try frame.fields.?.restore(self, frame.state));
}

pub fn finishLoweredLoop(handle: *const anyopaque) Error!u32 {
    const value = try completeLoopResult(handle);

    if (loopProjects(handle)) {
        if (loopFirstTest(handle)) |first| return finishSkippedLoop(handle, value, first);

        return finishProjectedLoop(handle, value);
    }

    return if (loopHasInitialGuard(handle)) finishGuardedLoop(handle, value) else value;
}

fn resultConfig(frame: *Frame) result.Result {
    return .{
        .consumer = frame.consumer,
        .deep = frame.initial.deep,
        .context = &frame.context,
        .converted = frame.initial.state_scope,
        .type_id = frame.type_id,
        .by_value = frame.initial.by_value,
        .local = frame.initial.local,
        .selected_state = frame.initial.selected_state,
        .initial = frame.initial_value,
        .changed_name = frame.changed_name,
        .mode = frame.mode,
    };
}

pub fn completeLoopResult(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try resultConfig(frame).lower(frame.lowering, frame.output(), frame.recovered, frame.prefix));
}

pub fn loopFirstTest(handle: *const anyopaque) ?u32 {
    const frame = Frame.borrow(handle);

    return if (frame.next.first) |first| @backingInt(first) else null;
}

pub fn finishSkippedLoop(handle: *const anyopaque, value: u32, first: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    var skipped = Frame.statements(self);

    defer if (generated) skipped.deinit();

    const fallback = try resultConfig(frame).lower(self, &skipped, frame.seed, .{});

    return @backingInt(try aggregate.finishGuarded(self, &frame.body, @fromBackingInt(first), @fromBackingInt(value), fallback));
}

pub fn finishProjectedLoop(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.finish(frame.lowering, &frame.body, @fromBackingInt(value)));
}

pub fn loopHasInitialGuard(handle: *const anyopaque) bool {
    return Frame.borrow(handle).guard != null;
}

pub fn finishGuardedLoop(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.guard.?.finish(frame.lowering, @fromBackingInt(value)));
}
