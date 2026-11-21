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

pub fn enterLoopUpdate(handle: *const anyopaque) *const Frame.Operands {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.step_scope = if (frame.fields) |*fields|
        .{ .projected = scope.enter(self, .Projected, .{ .loop_fields = fields }) }

    else
        .{ .ordinary = scope.enter(self, .Deferred, .{ .deferred_lists = frame.renewals.delayed }) };

    frame.operands = .{
        .condition = frame.schedule.condition,
        .body = frame.schedule.step,
        .by_value = frame.schedule.by_value,
    };

    return &frame.operands;
}

pub fn saveLoopUpdate(handle: *const anyopaque, condition: u32, value: u32, first: ?u32) void {
    const frame = Frame.borrow(handle);

    frame.restoreUpdate();

    frame.next = .{
        .condition = @fromBackingInt(condition),
        .value = @fromBackingInt(value),
        .first = if (first) |id| @fromBackingInt(id) else null,
    };
}

pub fn declareLoopState(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const projected = frame.fields != null;
    const type_id = frame.type_id;
    const name = if (projected) self.builder.nodes.get(frame.seed).identifier else frame.name;

    const layout = if (projected) try self.layoutExpr(type_id) else switch (frame.initial.parameters) {
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
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.growth = try frame.renewals.store(self, frame.type_id, .{
        .reference = if (frame.fields != null) frame.seed else frame.state,
    });

    if (frame.fields) |*fields| {
        const body = frame.output();

        try fields.maskBorrowed(self, body);

        _ = try declarations.declare(self, body, .{
            .name = frame.name,
            .layout = fields.layout,
            .initial = try fields.initial(self),
        });
    }

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
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const output = frame.output();

    output.clearRetainingCapacity();

    frame.recovered = frame.state;

    if (frame.fields) |*fields| {
        if (frame.schedule.restore_projected) frame.recovered = try aggregate.bind(self, output, try fields.restore(self, frame.state));
    }
}

pub fn finishLoweredLoop(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    const finish: result.Result = .{
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

    const value = try finish.lower(self, frame.output(), frame.recovered, frame.prefix);

    if (frame.fields != null) {
        if (frame.next.first) |first| {
            var skipped = Frame.statements(self);

            defer if (generated) skipped.deinit();

            return @backingInt(try aggregate.finishGuarded(self, &frame.body, first, value, try finish.lower(self, &skipped, frame.seed, .{})));
        }

        return @backingInt(try aggregate.finish(self, &frame.body, value));
    }

    if (frame.guard) |*guard| return @backingInt(try guard.finish(self, value));

    return @backingInt(value);
}
