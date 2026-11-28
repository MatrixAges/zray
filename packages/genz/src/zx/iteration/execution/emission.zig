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
const publication = @import("../../construction/publication.zig");
const generated = @import("genz_options").generated_analysis;
const Error = Lower.Error;
const Api = @import("../../expressions/evaluate.zig").Api;
const Layout = @FieldType(@import("../initial.zig").Plan, "parameters");

pub fn lowerLoopFirstTest(handle: *anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const condition = frame.schedule.first_test orelse return null;
    const parameters = &frame.parameters.?;

    parameters.rename(frame.lowering.builder.nodes.get(frame.seed).identifier);
    defer parameters.rename(frame.name);

    return @backingInt(try frame.lowering.expr(@fromBackingInt(condition)));
}

pub fn enterLoopUpdate(frame: *Frame, update: Frame.UpdateScope, delayed: bool) void {
    const self = frame.lowering;

    frame.step_scope = switch (update) {
        .Projected => .{ .Projected = scope.enter(self, .Projected, .{ .loop_fields = &frame.fields.? }) },
        .Ordinary => .{ .Ordinary = scope.enter(self, .Deferred, .{ .deferred_lists = delayed }) },
        .None => unreachable,
    };
}

pub fn declareSeedState(handle: *anyopaque, form: Layout, projected: bool, mutable: bool, initial_state: u32) Error!void {
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

pub fn enterLoweredLoop(handle: *anyopaque) Error!struct { growth: node.Block, declarations: node.Block } {
    const frame = Frame.borrow(handle);
    const projected = frame.fields != null;
    const growth = try renew_seed.store(frame.lowering, frame.id, frame.type_id, .{ .reference = if (projected) frame.seed else frame.state });

    if (projected) {
        try maskLoopBorrowedFields(handle);
        try declareProjectedLoopState(handle);
    }

    const output = frame.output();
    const declaration_rows = try frame.lowering.builder.statements(output.items);

    output.clearRetainingCapacity();

    return .{ .growth = growth, .declarations = declaration_rows };
}

pub fn emitLoopRenewals(handle: *anyopaque, first: u64, end: u64, skipped: []const u64, filtered_inline: bool) Error!u64 {
    const frame = Frame.borrow(handle);

    const growth = try @import("../../growth/delivery.zig").entry(frame.lowering, .{
        .type_id = frame.type_id,
        .target = .{ .reference = if (frame.fields != null) frame.seed else frame.state },
        .first = @intCast(first),
        .end = @intCast(end),
        .skipped = skipped,
        .filtered_inline = filtered_inline,
    });

    return publication.packSpan(growth);
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

pub fn writeLoopUpdate(handle: *anyopaque) Error!node.Block {
    const frame = Frame.borrow(handle);

    return step.store(frame.lowering, &frame.loop, frame.schedule, .{
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

pub fn recoverLoweredLoop(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    frame.output().clearRetainingCapacity();

    return if (frame.schedule.restore_projected) restoreLoopFields(handle) else @backingInt(frame.state);
}

pub fn restoreLoopFields(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return @backingInt(try aggregate.bind(self, frame.output(), try frame.fields.?.restore(self, frame.state)));
}

pub fn finishLoweredLoop(handle: *anyopaque, state: u32, spans: result.Prefix) Error!u32 {
    const frame = Frame.borrow(handle);
    const initial = @backingInt(frame.initial_value);

    const value = @backingInt(try resultConfig(frame, frame.initial_value, frame.changed_name).lower(
        frame.lowering,
        frame.output(),
        @fromBackingInt(state),
        spans,
    ));

    if (frame.fields != null) {
        if (frame.next.first) |first| return finishSkippedLoop(handle, initial, value, @backingInt(first), frame.changed_name);

        return @backingInt(try aggregate.finish(frame.lowering, &frame.body, @fromBackingInt(value)));
    }

    return if (frame.guard) |*guard| @backingInt(try guard.finish(frame.lowering, @fromBackingInt(value))) else value;
}

fn resultConfig(frame: *Frame, initial: node.ExpressionId, changed_name: []const u8) result.Result {
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
        .changed_name = changed_name,
        .mode = frame.mode,
    };
}

fn finishSkippedLoop(handle: *anyopaque, initial: u32, value: u32, first: u32, changed_name: ?[]const u8) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    var skipped = Frame.statements(self);

    defer if (generated) skipped.deinit();

    const fallback = try resultConfig(frame, @fromBackingInt(initial), changed_name orelse &.{}).lower(self, &skipped, frame.seed, .{});

    return @backingInt(try aggregate.finishGuarded(self, &frame.body, @fromBackingInt(first), @fromBackingInt(value), fallback));
}
