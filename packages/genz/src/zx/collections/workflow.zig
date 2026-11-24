const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const aggregate = @import("../aggregate.zig");
const lists = @import("../state_value/list.zig");
const elements = @import("../state_value/elements.zig");
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
        layout: ?node.ExpressionId,
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

    pub fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
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
        .layout = layout,
        .removed_only = removed_only,
    };

    defer frame.body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .kind = @fromBackingInt(@backingInt(operation.kind)),
        .target = @backingInt(operation.target),
        .arguments = @import("../../node/view.zig").slice([]const u32, operation.arguments),
        .frontier = flags.frontier,
        .removed_only = removed_only,
        .layout = if (layout) |target| @backingInt(target) else null,
    };

    return @fromBackingInt(entry.executeIn(frame.temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err));
}

pub fn evaluateCollectionValue(handle: *const anyopaque, origin: u32) Error!u32 {
    return @backingInt(try Frame.borrow(handle).lower.expr(@fromBackingInt(origin)));
}

pub fn collectionTargetRepresented(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return lists.selected(frame.lower, frame.source_type);
}

pub fn clipCollectionTarget(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../state_value/ownership.zig").clip(frame.lower, &frame.body, frame.target, @fromBackingInt(value)));
}

pub fn bindCollectionValue(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.bind(frame.lower, &frame.body, @fromBackingInt(value)));
}

pub fn readCollectionItems(handle: *const anyopaque, origin: u32, value: u32) Error!u32 {
    const self = Frame.borrow(handle).lower;
    const type_id: ir.TypeId = @fromBackingInt(self.program.expressions.types[origin]);

    return @backingInt(try lists.items(self, type_id, @fromBackingInt(value)));
}

pub fn writeCollectionElement(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try elements.write(frame.lower, &frame.body, frame.source_type, @fromBackingInt(value)));
}

pub fn collectionHeader(handle: *const anyopaque, value: u32) Error!u32 {
    return @backingInt(try lists.headered(Frame.borrow(handle).lower, @fromBackingInt(value)));
}

pub fn collectionFlag(handle: *const anyopaque, value: bool) Error!u32 {
    return @backingInt(try Frame.borrow(handle).lower.builder.expression(.{ .boolean = value }));
}

pub fn collectionElementType(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try elements.typeExpr(frame.lower, frame.source_type));
}

pub fn collectionLength(handle: *const anyopaque, items: u32) Error!u32 {
    return @backingInt(try Frame.borrow(handle).lower.field(@fromBackingInt(items), "len"));
}

pub fn collectionUnit(handle: *const anyopaque) Error!u32 {
    return @backingInt(try Frame.borrow(handle).lower.builder.expression(.unit));
}

pub fn collectionResultNeedsConversion(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);
    const self = frame.lower;

    return self.state_active and !self.state_plan.selected[@backingInt(frame.operation.?.result_type)];
}

pub fn convertCollectionResult(handle: *const anyopaque, result: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("result.zig").lower(frame.lower, &frame.body, frame.operation.?.result_type, @fromBackingInt(result)));
}

pub fn finalizeCollectionResult(handle: *const anyopaque, result: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("finalize.zig").lower(frame.lower, frame.operation.?.result_type, @fromBackingInt(result), frame.operation.?.layout));
}

pub fn castCollectionResult(handle: *const anyopaque, layout: u32, result: u32) Error!u32 {
    const self = Frame.borrow(handle).lower;

    return @backingInt(try self.cast(@fromBackingInt(layout), @fromBackingInt(result)));
}

pub fn finishCollection(handle: *const anyopaque, result: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.finish(frame.lower, &frame.body, @fromBackingInt(result)));
}
