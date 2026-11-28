const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const consumer = @import("../iteration_consumer.zig");
const planning = @import("result_plan.zig");
const Context = @import("root.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Api = evaluation.Api;

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

    var resources: Context.Resources = undefined;
    const previous_body = if (context) |owner| owner.active_body else null;

    if (context) |owner| resources.push(owner);

    defer if (context != null) resources.pop();

    if (@TypeOf(body) != void) context.?.active_body = body;

    defer if (context) |owner| {
        owner.active_body = previous_body;
    };

    const application = @import("generated_apply_iteration_result");
    const Input = std.meta.Child(application.Input);

    const input: Input = .{
        .lower = @ptrCast(lowering),
        .plan = @import("zx").columns.pointer(@FieldType(Input, "plan"), plan),
        .consumer = &.{
            .symbol = @backingInt(selected.symbol),
            .result = @backingInt(selected.result),
            .result_type = lowering.program.expressions.types[@backingInt(selected.result)],
            .layout = selected.layout,
        },
        .state = @backingInt(state),
        .buffered = context != null,
    };

    const result = application.executeIn(temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(result);
}

pub fn projectIterationResult(frame: *anyopaque, is_buffered: bool, source: *const Api.LoopConsumer, state: u32, raw: ?u32) Lower.Error!u32 {
    const lowering = evaluation.borrow(frame);

    const selected: consumer.Consumer = .{
        .symbol = @fromBackingInt(source.symbol),
        .result = @fromBackingInt(source.result),
        .layout = source.layout,
    };

    const value: node.ExpressionId = @fromBackingInt(state);

    if (raw) |id| {
        return @backingInt(if (is_buffered)
            try @import("projection_emission.zig").lower(lowering.iteration_resources.?.context, selected, @fromBackingInt(id), value)
        else
            try consumer.read(lowering, selected, @fromBackingInt(id), value));
    }

    if (is_buffered) {
        const context = lowering.iteration_resources.?.context;

        return @backingInt(try buffered(context, context.declarations, selected, value));
    }

    return @backingInt(try lower(lowering, selected, value));
}

pub fn transferIterationResult(allocator: std.mem.Allocator, handle: *anyopaque, id: u32, value: u32) Lower.Error!*const Api.IterationTransferResult {
    const context = evaluation.borrow(handle).iteration_resources.?.context;
    const type_id: ir.TypeId = @fromBackingInt(context.lowering.program.expressions.types[id]);
    const moved = try @import("transfer.zig").lower(context, context.active_body.?, type_id, @fromBackingInt(value));
    const result = try allocator.create(Api.IterationTransferResult);
    result.* = .{ .root = @backingInt(moved.root), .cached = @backingInt(moved.cached) };

    return result;
}
