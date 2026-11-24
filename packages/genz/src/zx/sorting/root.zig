const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const rows = @import("../construction/publication.zig");
const Api = evaluation.Api;
const aggregate = @import("../aggregate.zig");
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
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.Transform) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("root_seed.zig").lower(self, id, value);

    const entry = @import("generated_execute_sort");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};
    const resource: rows.Scratch = .{ .arena = &scratch, .memory = &memory };

    defer scratch.deinit();

    var frame: Frame = .{
        .lowering = self,
        .id = id,
        .value = value,
        .list_type = self.program.expression(value.target).type_id,
        .body = self.builder.statementSequence(self.workspace),
    };

    defer frame.body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .body = @ptrCast(&frame.body),
        .origin = @ptrCast(&origin),
        .scratch = @ptrCast(&resource),
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn sortElementType(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../state_value/elements.zig").typeExpr(frame.lowering, frame.list_type));
}

pub fn sortErrors(handle: *const anyopaque) Error!?[]const []const u8 {
    const frame = Frame.borrow(handle);

    return @import("../error_effects.zig").expression(frame.lowering, frame.id);
}

pub fn buildSortComparator(handle: *const anyopaque, child: u32, errors: ?[]const []const u8) Error!*const Api.SortComparator {
    const frame = Frame.borrow(handle);
    const result = try worker.build(frame.lowering, frame.value, @fromBackingInt(child), errors);

    frame.comparator = .{ .declaration = result.declaration, .io = result.io, .process = result.process };

    return &frame.comparator;
}

pub fn publishSortEffects(handle: *const anyopaque, comparator: *const Api.SortComparator) void {
    const self = Frame.borrow(handle).lowering;

    self.uses_allocator = true;
    self.uses_io = self.uses_io or comparator.io;
    self.uses_process = self.uses_process or comparator.process;
}

pub fn evaluateSortTarget(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.expr(frame.value.target));
}

pub fn sortSourceSelected(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return lists.selected(frame.lowering, frame.list_type);
}

pub fn clipSortTarget(handle: *const anyopaque, target: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const ownership = @import("../state_value/ownership.zig");

    return @backingInt(try ownership.clip(frame.lowering, &frame.body, frame.value.target, @fromBackingInt(target)));
}

pub fn bindSortValue(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(value)));
}

pub fn readSortItems(handle: *const anyopaque, target: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try lists.items(frame.lowering, frame.list_type, @fromBackingInt(target)));
}

pub fn sortInputReusable(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return frame.lowering.plan.get(frame.id).in_place;
}

pub fn sortWritable(handle: *const anyopaque, target: u32) Error!u32 {
    return @backingInt(try lists.writable(Frame.borrow(handle).lowering, @fromBackingInt(target)));
}

pub fn sortReuseFlag(handle: *const anyopaque, reuse: bool) Error!u32 {
    return @backingInt(try Frame.borrow(handle).lowering.builder.expression(.{ .boolean = reuse }));
}

pub fn bindSortEnvironment(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const environment = try frame.lowering.expr(frame.value.initial.?);

    return bindSortValue(handle, @backingInt(environment));
}

pub fn readSortHeader(handle: *const anyopaque, target: u32) Error!u32 {
    return @backingInt(try lists.headered(Frame.borrow(handle).lowering, @fromBackingInt(target)));
}

pub fn finishSortResult(handle: *const anyopaque, result: u32, headered: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const value = try lists.owned(self, frame.list_type, @fromBackingInt(result), @fromBackingInt(headered));

    return @backingInt(try aggregate.finish(self, &frame.body, value));
}
