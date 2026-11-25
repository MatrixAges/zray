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

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .target = @backingInt(update.target),
        .index = @backingInt(update.index),
        .value = @backingInt(update.value),
    };

    return @fromBackingInt(entry.executeIn(frame.temporary, &input) catch |err| return publication.failure(err));
}

pub fn checkCollectionIndex(handle: *anyopaque, items: u32, index: u32) Error!void {
    const frame = Frame.borrow(handle);
    const entry = @import("generated_list_update_bounds");
    const Input = std.meta.Child(entry.Input);
    const bases = context.snapshot(std.meta.Child(@FieldType(Input, "bases")), frame.lower);
    const input: Input = .{ .bases = &bases, .items = items, .index = index };
    const output = entry.executeIn(frame.temporary, &input) catch |err| return publication.failure(err);

    return publication.write(frame.lower, .{ .body = &frame.body }, output, .Guard);
}

pub fn emitCollectionUpdate(handle: *anyopaque, request: *const Api.CollectionUpdate) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const entry = @import("generated_list_update");
    const Input = std.meta.Child(entry.Input);
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

    const output = entry.executeIn(frame.temporary, &input) catch |err| return publication.failure(err);

    try publication.write(self, .{ .body = &frame.body }, output, .Update);

    return output.root;
}
