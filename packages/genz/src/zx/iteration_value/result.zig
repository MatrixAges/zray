const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const consumer = @import("../iteration_consumer.zig");
const planning = @import("result_plan.zig");

pub fn eligible(lowering: *Lower, selected: consumer.Consumer) Lower.Error!bool {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").eligible(lowering, selected);

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered_allocator = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = try planning.analyze(buffered_allocator.allocator(), &lowering.program, &lowering.cache, selected, .Eligible, lowering.capture != null);

    return plan.valid;
}

pub fn candidate(allocator: std.mem.Allocator, program: ir.Program, selected: consumer.Consumer) Lower.Error!bool {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").candidate(allocator, program, selected);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered_allocator = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = try planning.analyze(buffered_allocator.allocator(), &program, null, selected, .Candidate, false);

    return plan.valid;
}

pub fn lower(lowering: *Lower, selected: consumer.Consumer, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").lower(lowering, selected, state);

    return materialize(lowering, null, {}, selected, state);
}

pub fn buffered(context: *@import("root.zig"), body: anytype, selected: consumer.Consumer, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("result_seed.zig").buffered(context, body, selected, state);

    std.debug.assert(context.inline_lists);

    return materialize(context.lowering, context, body, selected, state);
}

fn materialize(lowering: *Lower, context: ?*@import("root.zig"), body: anytype, selected: consumer.Consumer, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered_allocator = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered_allocator.allocator();

    const plan = if (@TypeOf(body) == void)
        try planning.analyze(temporary, &lowering.program, &lowering.cache, selected, .Plan, false)
    else
        try planning.analyze(temporary, &lowering.program, &lowering.cache, selected, .Buffered, false);

    if (plan.primitive) return project(lowering, context, selected, selected.result, state);

    std.debug.assert(plan.valid);
    defer lowering.cache.removeKeys(plan.projections);

    if (comptime @TypeOf(body) != void) {
        const values = try temporary.alloc(node.ExpressionId, @intCast(plan.transfer_count));

        for (plan.transfers, plan.slots, plan.reuse) |raw, slot, reuse| {
            const id: ir.ExprId = @fromBackingInt(raw);
            const value = try project(lowering, context, selected, id, state);

            const result = if (reuse) values[@intCast(slot)] else first: {
                const type_id: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[raw]);
                const moved = try @import("transfer.zig").lower(context.?, body, type_id, value);

                values[@intCast(slot)] = moved.cached;

                break :first moved.root;
            };

            try lowering.cache.put(lowering.allocator, id, result);
        }
    }

    for (plan.reads orelse plan.projections) |raw| {
        const id: ir.ExprId = @fromBackingInt(raw);

        try lowering.cache.put(lowering.allocator, id, try project(lowering, context, selected, id, state));
    }

    return if (selected.layout) @import("../value_call/root.zig").expression(lowering, selected.result) else lowering.expr(selected.result);
}

fn project(lowering: *Lower, context: ?*@import("root.zig"), selected: consumer.Consumer, id: ir.ExprId, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (context) |buffer| return @import("projection.zig").read(buffer, selected, id, state);

    return consumer.read(lowering, selected, id, state);
}
