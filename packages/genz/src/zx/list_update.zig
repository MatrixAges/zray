const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const Frame = @import("collections/workflow.zig").Frame;
const publication = @import("construction/publication.zig");
const Error = Lower.Error;

pub fn lower(self: *Lower, id: ir.ExprId) Error!node.ExpressionId {
    if (comptime !@import("genz_options").generated_analysis) return @import("list_update_seed.zig").lower(self, id);

    const update = self.program.expression(id).value.list_update;
    const entry = @import("generated_run_list_update");
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());
    var frame = Frame.init(self, id, update.target, memory.allocator());
    const flags = self.plan.get(id);
    const represented = @import("state_value/list.zig").selected(self, frame.source_type);

    defer scratch.deinit();
    defer frame.body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .ast = &.{
            .lower = @ptrCast(self),
            .writer = @ptrCast(self),
            .sequence = @ptrCast(&frame.body),
        },
        .represented = represented,
        .deferred = represented and self.deferred_lists,
        .in_place = flags.in_place,
        .grow = flags.grow,
        .exact = !self.may_grow,
        .shared = self.shared_types,
        .source_type = @backingInt(frame.source_type),
        .target = @backingInt(update.target),
        .index = @backingInt(update.index),
        .value = @backingInt(update.value),
    };

    return @fromBackingInt(entry.executeIn(frame.temporary, &input) catch |err| return publication.failure(err));
}
