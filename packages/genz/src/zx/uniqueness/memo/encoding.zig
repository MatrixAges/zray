const std = @import("std");
const Memo = @import("../memo.zig");
const Summaries = @import("../summaries.zig");
const Level = @import("../level.zig").Level;
const Growth = @import("../growth.zig");
const zx = @import("zx");
const encoding = @import("generated_uniqueness_memo_key");
const creating = @import("generated_uniqueness_memo_create");
const State = @typeInfo(@typeInfo(@TypeOf(creating.executeState)).@"fn".return_type.?).error_union.payload;
const Parameter = @typeInfo(@TypeOf(encoding.executeState)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Self = @This();

state: State,
order: zx.memory.U32Scratch,
pub fn init(backing: std.mem.Allocator) Self {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const state = creating.executeState(empty.allocator(), {}) catch unreachable;

    return .{ .state = state, .order = .{ .allocator = backing } };
}

pub fn deinit(self: *Self) void {
    self.order.deinit();
}

pub fn probe(self: *Self, allocator: std.mem.Allocator, comptime kind: Memo.Kind, summaries: *const Summaries, body: *const Memo.State, table: anytype, digest: *Memo.Digest, comptime mark: bool) std.mem.Allocator.Error!?u32 {
    comptime std.debug.assert(@sizeOf(Level) == @sizeOf(u8) and @alignOf(Level) == @alignOf(u8));

    const normalized = Growth.Columns.borrow(body.growth.normalized);
    const renewed = Growth.Columns.borrow(body.growth.renewed);
    const Table = std.meta.Child(@FieldType(Input, "table"));
    const target: []u8 = digest;
    const used = if (mark) table.useColumn() else {};

    const input: Input = .{
        .state = self.state,
        .identity = .{ .items = &body.identity, .storage = .plain },
        .index = body.index,
        .kind = @fromBackingInt(@backingInt(kind)),
        .callees = .{ .items = body.callees, .storage = .plain },
        .own_input = .{ .items = std.mem.sliceAsBytes(body.input), .storage = .plain },
        .called_outputs = .{ .items = @ptrCast(summaries.output), .storage = .plain },
        .output_wants = .{ .items = @ptrCast(summaries.outputs), .storage = .plain },
        .called_input_wants = .{ .items = @ptrCast(summaries.inputs), .storage = .plain },
        .normalized = &.{
            .count = body.growth.normalized.len,
            .columns = &.{ .keys = @ptrCast(&normalized.keys), .wants = @ptrCast(&normalized.wants), .wide = normalized.wide },
        },
        .renewed = &.{
            .count = body.growth.renewed.len,
            .columns = &.{ .keys = @ptrCast(&renewed.keys), .wants = @ptrCast(&renewed.wants), .wide = renewed.wide },
        },
        .order = &.{ .indices = @ptrCast(&self.order.items), .scratch = @ptrCast(&self.order) },
        .digest = @ptrCast(&target),
        .table = &table.probe(Table, if (mark) &used else null),
    };

    const result = encoding.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);

    self.state = result.state;

    return result.row;
}

pub fn stateEnd(self: *const Self) usize {
    return @intCast(self.state.state_end);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.state.buffer.items[0..@intCast(self.state.end)];
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("memo encoding failed: {s}", .{@errorName(err)});
}
