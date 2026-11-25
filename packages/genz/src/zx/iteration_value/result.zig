const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const consumer = @import("../iteration_consumer.zig");
const planning = @import("result_plan.zig");
const Context = @import("root.zig");

const Frame = struct {
    lowering: *Lower,
    context: ?*Context,
    body: ?*Context.Statements,
    selected: consumer.Consumer,
    state: node.ExpressionId,
    temporary: std.mem.Allocator,
    slots: []u32 = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn eligible(lowering: *Lower, selected: consumer.Consumer) Lower.Error!bool {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").eligible(lowering, selected);

    return planning.valid(lowering.workspace, &lowering.program, &lowering.cache, selected, .Eligible, lowering.capture != null);
}

pub fn candidate(allocator: std.mem.Allocator, program: ir.Program, selected: consumer.Consumer) Lower.Error!bool {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").candidate(allocator, program, selected);

    return planning.valid(allocator, &program, null, selected, .Candidate, false);
}

pub fn lower(lowering: *Lower, selected: consumer.Consumer, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").lower(lowering, selected, state);

    return materialize(lowering, null, {}, selected, state);
}

pub fn buffered(context: *Context, body: anytype, selected: consumer.Consumer, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").buffered(context, body, selected, state);

    std.debug.assert(context.inline_lists);

    return materialize(context.lowering, context, body, selected, state);
}

fn materialize(lowering: *Lower, context: ?*Context, body: anytype, selected: consumer.Consumer, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered_allocator = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered_allocator.allocator();

    const plan = if (@TypeOf(body) == void)
        try planning.analyze(temporary, &lowering.program, &lowering.cache, selected, .Plan, false)
    else
        try planning.analyze(temporary, &lowering.program, &lowering.cache, selected, .Buffered, false);

    std.debug.assert(plan.primitive or plan.valid);
    defer if (!plan.primitive) lowering.cache.removeKeys(plan.projections);

    const application = @import("generated_apply_iteration_result");
    const Input = std.meta.Child(application.Input);

    var frame: Frame = .{
        .lowering = lowering,
        .context = context,
        .body = if (@TypeOf(body) == void) null else body,
        .selected = selected,
        .state = state,
        .temporary = temporary,
    };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .lower = @ptrCast(lowering),
        .plan = @import("zx").columns.pointer(@FieldType(Input, "plan"), plan),
        .slots = @ptrCast(&frame.slots),
        .result = @backingInt(selected.result),
        .buffered = @TypeOf(body) != void,
        .layout = selected.layout,
    };

    const result = application.executeIn(temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(result);
}

pub fn reserveIterationTransferSlots(handle: *anyopaque, count: u64) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.slots = try frame.temporary.alloc(u32, @intCast(count));
}

pub fn projectIterationResult(handle: *anyopaque, raw: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const id: ir.ExprId = @fromBackingInt(raw);

    const value = if (frame.context) |context|
        try @import("projection_emission.zig").lower(context, frame.selected, id, frame.state)
    else
        try consumer.read(frame.lowering, frame.selected, id, frame.state);

    return @backingInt(value);
}

pub fn transferIterationResult(handle: *anyopaque, id: u32, value: u32, slot: u64) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const type_id: ir.TypeId = @fromBackingInt(frame.lowering.program.expressions.types[id]);
    const moved = try @import("transfer.zig").lower(frame.context.?, frame.body.?, type_id, @fromBackingInt(value));

    frame.slots[@intCast(slot)] = @backingInt(moved.cached);

    return @backingInt(moved.root);
}

pub fn cacheIterationResult(handle: *anyopaque, id: u32, value: u32) Lower.Error!void {
    const lowering = Frame.borrow(handle).lowering;

    return lowering.cache.put(lowering.allocator, @fromBackingInt(id), @fromBackingInt(value));
}
