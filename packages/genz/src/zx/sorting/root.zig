const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const rows = @import("../construction/publication.zig");
const Api = evaluation.Api;
const lists = @import("../state_value/list.zig");
const worker = @import("worker.zig");
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    id: ir.ExprId,
    value: ir.Transform,
    list_type: ir.TypeId,
    body: blocks.Sequence,
    comparator: Api.SortComparator = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.Transform) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("root_seed.zig").lower(self, id, value);

    const entry = @import("generated_execute_sort");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};

    defer scratch.deinit();

    const list_type = self.program.expression(value.target).type_id;
    const errors = try @import("../error_effects.zig").expression(self, id);

    var frame: Frame = .{
        .lowering = self,
        .id = id,
        .value = value,
        .list_type = list_type,
        .body = self.builder.statementSequence(self.workspace),
    };

    defer frame.body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .body = @ptrCast(&frame.body),
        .origin = @ptrCast(&origin),
        .target = @backingInt(value.target),
        .environment = @backingInt(value.initial.?),
        .list_type = @backingInt(list_type),
        .selected = lists.selected(self, list_type),
        .reusable = self.plan.get(id).in_place,
        .errors = errors,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn buildSortComparator(handle: *anyopaque, child: u32, errors: ?[]const []const u8) Error!*const Api.SortComparator {
    const frame = Frame.borrow(handle);
    const result = try worker.build(frame.lowering, frame.value, @fromBackingInt(child), errors);

    frame.comparator = .{ .declaration = result.declaration, .io = result.io, .process = result.process };

    return &frame.comparator;
}

pub fn clipSortTarget(handle: *anyopaque, target: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const ownership = @import("../state_value/ownership.zig");

    return @backingInt(try ownership.clip(frame.lowering, &frame.body, frame.value.target, @fromBackingInt(target)));
}
