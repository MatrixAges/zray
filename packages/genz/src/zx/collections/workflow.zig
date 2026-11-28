const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const lists = @import("../state_value/list.zig");
const elements = @import("../state_value/elements.zig");
const evaluation = @import("../expressions/evaluate.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_run_collection_operation");
const Error = Lower.Error;

pub fn run(self: *Lower, id: ir.ExprId, layout: ?node.ExpressionId, removed_only: bool) Error!node.ExpressionId {
    const row = self.program.expression(id);
    const operation = row.value.list_operation;
    const flags = self.plan.get(id);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const source_type: ir.TypeId = @fromBackingInt(self.program.expressions.types[@backingInt(operation.target)]);
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .id = @backingInt(id),
        .ast = &.{
            .lower = @ptrCast(self),
            .writer = @ptrCast(self),
            .sequence = @ptrCast(&body),
        },
        .represented = lists.selected(self, source_type),
        .kind = @fromBackingInt(@backingInt(operation.kind)),
        .target = @backingInt(operation.target),
        .source_type = @backingInt(source_type),
        .result_type = @backingInt(row.type_id),
        .arguments = @import("../../node/view.zig").slice([]const u32, operation.arguments),
        .frontier = flags.frontier,
        .removed_only = removed_only,
        .state_active = self.state_active,
        .result_selected = self.state_active and self.state_plan.selected[@backingInt(row.type_id)],
        .layout = if (layout) |target| @backingInt(target) else null,
    };

    return @fromBackingInt(entry.executeIn(memory.allocator(), &input) catch |err| return publication.failure(err));
}

pub fn clipCollectionTarget(frame: *anyopaque, body: *anyopaque, target: u32, value: u32) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try @import("../state_value/ownership.zig").clip(lowering, sequence, @fromBackingInt(target), @fromBackingInt(value)));
}

pub fn writeCollectionElement(frame: *anyopaque, body: *anyopaque, list_type: u32, value: u32) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try elements.write(lowering, sequence, @fromBackingInt(list_type), @fromBackingInt(value)));
}

pub fn convertCollectionResult(frame: *anyopaque, body: *anyopaque, result_type: u32, result: u32) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try @import("result.zig").lower(lowering, sequence, @fromBackingInt(result_type), @fromBackingInt(result)));
}
