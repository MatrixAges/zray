const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const Api = @import("../expressions/evaluate.zig").Api;
const Branches = @FieldType(@FieldType(zx.ir.ExpressionRow, "value"), "parallel");

const Frame = struct {
    lowering: *Lower,
    type_id: zx.ir.TypeId,
    temporary: std.mem.Allocator,
    futures: [][]const u8,
    results: [][]const u8 = &.{},
    values: [][]const u8 = &.{},
    names: Api.TaskParallelNames = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, type_id: zx.ir.TypeId, branches: Branches) Lower.Error!node.ExpressionId {
    const entry = @import("generated_lower_parallel");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var body = self.builder.statementSequence(temporary);

    defer body.deinit();

    var frame: Frame = .{
        .lowering = self,
        .type_id = type_id,
        .temporary = temporary,
        .futures = try temporary.alloc([]const u8, branches.len),
    };

    const output_type = self.program.typeOf(type_id);

    const input: std.meta.Child(entry.Input) = .{
        .group = @ptrCast(&frame),
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .body = @ptrCast(&body),
        .tasks = branches.tasks[0..branches.len],
        .fields = branches.fields[0..branches.len],
        .object_names = if (output_type == .object) output_type.object.names else null,
        .results = @ptrCast(&frame.results),
        .values = @ptrCast(&frame.values),
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn startParallelBranch(handle: *anyopaque, index: u64, task: u32, future: []const u8) Lower.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.futures[@intCast(index)] = future;

    return rows.packSpan(try @import("root.zig").bind(frame.lowering, future, @fromBackingInt(task), true));
}

pub fn reserveParallelNames(handle: *anyopaque, count: u64) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.results = try frame.temporary.alloc([]const u8, @intCast(count));
    frame.values = try frame.temporary.alloc([]const u8, @intCast(count));
}

pub fn readParallelNames(handle: *anyopaque) *const Api.TaskParallelNames {
    const frame = Frame.borrow(handle);

    frame.names = .{ .futures = frame.futures, .results = frame.results, .values = frame.values };

    return &frame.names;
}

pub fn constructParallelResult(handle: *anyopaque, value: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.construct(frame.type_id, @fromBackingInt(value)));
}
