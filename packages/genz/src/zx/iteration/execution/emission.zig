const zx = @import("zx");
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const aggregate = @import("../../aggregate.zig");
const declarations = @import("../state.zig");
const step = @import("../step.zig");
const scope = @import("../../state_value/scope.zig");
const result = @import("../result.zig");
const renew_seed = @import("../renewal_seed.zig");
const generated = @import("genz_options").generated_analysis;
const Error = Lower.Error;
const Api = @import("../../expressions/evaluate.zig").Api;
const Layout = if (generated) Api.LoopParameterLayout else @import("../parameters_seed.zig").Layout;

pub fn lowerLoopFirstTest(handle: *anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const condition = frame.schedule.first_test orelse return null;
    const parameters = &frame.parameters.?;

    parameters.rename(frame.lowering.builder.nodes.get(frame.seed).identifier);
    defer parameters.rename(frame.name);

    return @backingInt(try frame.lowering.expr(@fromBackingInt(condition)));
}

pub fn renameIterationParameters(handle: *anyopaque, name: []const u8) void {
    const frame = Frame.borrow(handle);
    const iteration = frame.iteration;
    const names = frame.lowering.names;

    names[@backingInt(iteration.condition_parameter)] = name;
    names[@backingInt(iteration.parameter)] = name;
}

pub fn enterLoopUpdate(handle: *anyopaque, update: Frame.UpdateScope, delayed: bool) void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.step_scope = switch (update) {
        .Projected => .{ .Projected = scope.enter(self, .Projected, .{ .loop_fields = &frame.fields.? }) },
        .Ordinary => .{ .Ordinary = scope.enter(self, .Deferred, .{ .deferred_lists = delayed }) },
        .None => unreachable,
    };
}

pub fn declareLoopState(handle: *anyopaque, form: Layout, projected: bool, mutable: bool, initial_state: u32) Error!void {
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
        .initial = @fromBackingInt(initial_state),
        .mutable = mutable,
        .tracking = if (frame.changed_name.len != 0) frame.changed_name else null,
    });
}

pub fn enterLoweredLoop(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const projected = frame.fields != null;

    frame.growth = try renew_seed.store(frame.lowering, frame.id, frame.type_id, .{ .reference = if (projected) frame.seed else frame.state });

    if (projected) {
        try maskLoopBorrowedFields(handle);
        try declareProjectedLoopState(handle);
    }

    return publishLoopDeclarations(handle);
}

pub fn emitLoopRenewals(handle: *anyopaque, first: u64, end: u64, skipped: []const u64, filtered_inline: bool) Error!void {
    const frame = Frame.borrow(handle);

    frame.growth = try @import("../../growth/delivery.zig").entry(frame.lowering, .{
        .type_id = frame.type_id,
        .target = .{ .reference = if (frame.fields != null) frame.seed else frame.state },
        .first = @intCast(first),
        .end = @intCast(end),
        .skipped = skipped,
        .filtered_inline = filtered_inline,
    });
}

pub fn maskLoopBorrowedFields(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return frame.fields.?.maskBorrowed(frame.lowering, frame.output());
}

pub fn declareProjectedLoopState(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const fields = &frame.fields.?;
    const self = frame.lowering;

    _ = try declarations.declare(self, frame.output(), .{
        .name = frame.name,
        .layout = fields.layout,
        .initial = try fields.initial(self),
    });
}

pub fn publishLoopDeclarations(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const output = frame.output();

    frame.prefix.declarations = if (generated) try output.block(self.allocator) else try self.builder.statements(output.items);

    output.clearRetainingCapacity();

    frame.recovered = frame.state;
}

pub fn writeLoopUpdate(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.update = try step.store(frame.lowering, &frame.loop, frame.schedule, .{
        .type_id = frame.type_id,
        .origin = frame.iteration.body,
        .target = frame.state,
        .value = frame.next.value,
        .fields = if (frame.fields) |*fields| fields else null,
    }, frame.tracker);
}

pub fn projectLoopAssignment(handle: *anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.fields.?.qualify(frame.lowering, &frame.loop, frame.iteration.body, @fromBackingInt(value)));
}

pub fn commitLoopUpdate(handle: *anyopaque, value: u32, state: bool) Error!void {
    const frame = Frame.borrow(handle);

    frame.update = try step.publish(frame.lowering, &frame.loop, .{
        .type_id = frame.type_id,
        .active = state and frame.lowering.state_active,
        .target = frame.state,
        .value = @fromBackingInt(value),
        .mark = if (frame.tracker) |flag| flag.generated else null,
    });
}

pub fn frameLoweredLoop(handle: *anyopaque, condition: u32, after_step: bool) Error!void {
    const frame = Frame.borrow(handle);
    const projected = frame.fields != null;

    frame.prefix.renewals = if (projected) frame.growth else .{};

    frame.prefix.frame = try @import("../frame.zig").lower(frame.lowering, if (projected) .{} else frame.growth, frame.update, .{
        .condition = @fromBackingInt(condition),
        .after_step = after_step,
        .guarded_initial = !projected and frame.guard != null,
    });
}

pub fn recoverLoweredLoop(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.output().clearRetainingCapacity();

    frame.recovered = frame.state;

    if (frame.schedule.restore_projected) try restoreLoopFields(handle);
}

pub fn restoreLoopFields(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.recovered = try aggregate.bind(self, frame.output(), try frame.fields.?.restore(self, frame.state));
}

pub fn finishLoweredLoop(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const initial = @backingInt(frame.initial_value);
    const value = try completeLoopResult(handle, initial);

    if (frame.fields != null) {
        if (frame.next.first) |first| return finishSkippedLoop(handle, initial, value, @backingInt(first));

        return @backingInt(try aggregate.finish(frame.lowering, &frame.body, @fromBackingInt(value)));
    }

    return if (frame.guard) |*guard| @backingInt(try guard.finish(frame.lowering, @fromBackingInt(value))) else value;
}

fn resultConfig(frame: *Frame, initial: node.ExpressionId) result.Result {
    return .{
        .consumer = frame.consumer,
        .deep = frame.initial.deep,
        .context = &frame.context,
        .converted = frame.initial.state_scope,
        .type_id = frame.type_id,
        .by_value = frame.initial.by_value,
        .local = frame.initial.local,
        .selected_state = frame.initial.selected_state,
        .initial = initial,
        .changed_name = frame.changed_name,
        .mode = frame.mode,
    };
}

pub fn completeLoopResult(handle: *anyopaque, initial: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try resultConfig(frame, @fromBackingInt(initial)).lower(frame.lowering, frame.output(), frame.recovered, frame.prefix));
}

pub fn finishSkippedLoop(handle: *anyopaque, initial: u32, value: u32, first: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    var skipped = Frame.statements(self);

    defer if (generated) skipped.deinit();

    const fallback = try resultConfig(frame, @fromBackingInt(initial)).lower(self, &skipped, frame.seed, .{});

    return @backingInt(try aggregate.finishGuarded(self, &frame.body, @fromBackingInt(first), @fromBackingInt(value), fallback));
}
