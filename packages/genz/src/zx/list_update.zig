const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const Frame = @import("collections/workflow.zig").Frame;
const Api = @import("expressions/evaluate.zig").Api;
const context = @import("construction/context.zig");
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

    defer scratch.deinit();
    defer frame.body.deinit();

    var origin: publication.OriginBuffer = undefined;

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .ast = &.{
            .lower = @ptrCast(self),
            .writer = @ptrCast(self),
            .origin = @ptrCast(&origin),
            .sequence = @ptrCast(&frame.body),
        },
        .represented = @import("state_value/list.zig").selected(self, frame.source_type),
        .target = @backingInt(update.target),
        .index = @backingInt(update.index),
        .value = @backingInt(update.value),
    };

    return @fromBackingInt(entry.executeIn(frame.temporary, &input) catch |err| return publication.failure(err));
}

pub fn emitCollectionUpdate(handle: *anyopaque, request: *const Api.CollectionUpdate) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const entry = @import("generated_list_update");
    const Call = std.meta.Child(entry.Input);
    const Input = std.meta.Child(@FieldType(Call, "update"));
    const layout = if (request.selected) try @import("types.zig").get(self, self.state_types, frame.source_type) else null;
    const flags = self.plan.get(frame.id);
    const bases = context.snapshot(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .bases = &bases,
        .items = request.items,
        .target = request.target,
        .index = request.index,
        .value = request.value,
        .element = request.element,
        .layout = if (layout) |value| @backingInt(value) else 0,
        .selected = request.selected,
        .deferred = request.selected and self.deferred_lists,
        .in_place = flags.in_place,
        .grow = flags.grow,
        .exact = !self.may_grow,
        .shared = self.shared_types,
    };

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(&frame.body),
        .update = &input,
    };

    return entry.executeIn(frame.temporary, &call) catch |err| return publication.failure(err);
}
