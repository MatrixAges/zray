const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const lists = @import("../state_value/list.zig");
const elements = @import("../state_value/elements.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_run_collection_operation");
const Error = Lower.Error;

pub const Frame = struct {
    lower: *Lower,
    body: Sequence,
    temporary: std.mem.Allocator,
    id: ir.ExprId,
    target: ir.ExprId,
    source_type: ir.TypeId,
    operation: ?Operation = null,
    const Operation = struct {
        result_type: ir.TypeId,
        kind: ir.ListOperation,
        flags: @import("../uniqueness/root.zig").Flags,
        removed_only: bool,
    };
    pub fn init(self: *Lower, id: ir.ExprId, target: ir.ExprId, temporary: std.mem.Allocator) Frame {
        return .{
            .lower = self,
            .body = self.builder.statementSequence(self.workspace),
            .temporary = temporary,
            .id = id,
            .target = target,
            .source_type = @fromBackingInt(self.program.expressions.types[@backingInt(target)]),
        };
    }

    pub fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(self: *Lower, id: ir.ExprId, layout: ?node.ExpressionId, removed_only: bool) Error!node.ExpressionId {
    const row = self.program.expression(id);
    const operation = row.value.list_operation;
    const flags = self.plan.get(id);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var frame = Frame.init(self, id, operation.target, memory.allocator());

    frame.operation = .{
        .result_type = row.type_id,
        .kind = operation.kind,
        .flags = flags,
        .removed_only = removed_only,
    };

    defer frame.body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .ast = &.{
            .lower = @ptrCast(self),
            .writer = @ptrCast(self),
            .sequence = @ptrCast(&frame.body),
        },
        .represented = lists.selected(self, frame.source_type),
        .kind = @fromBackingInt(@backingInt(operation.kind)),
        .target = @backingInt(operation.target),
        .source_type = @backingInt(frame.source_type),
        .result_type = @backingInt(row.type_id),
        .arguments = @import("../../node/view.zig").slice([]const u32, operation.arguments),
        .frontier = flags.frontier,
        .removed_only = removed_only,
        .state_active = self.state_active,
        .result_selected = self.state_active and self.state_plan.selected[@backingInt(row.type_id)],
        .layout = if (layout) |target| @backingInt(target) else null,
    };

    return @fromBackingInt(entry.executeIn(frame.temporary, &input) catch |err| return publication.failure(err));
}

pub fn clipCollectionTarget(handle: *anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../state_value/ownership.zig").clip(frame.lower, &frame.body, frame.target, @fromBackingInt(value)));
}

pub fn writeCollectionElement(handle: *anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try elements.write(frame.lower, &frame.body, frame.source_type, @fromBackingInt(value)));
}

pub fn convertCollectionResult(handle: *anyopaque, result: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("result.zig").lower(frame, @fromBackingInt(result)));
}
