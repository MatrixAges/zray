const std = @import("std");
const Memo = @import("../memo.zig");
const Summaries = @import("../summaries.zig");
const Level = @import("../level.zig").Level;
const columns = @import("zx").columns;
const encoding = @import("generated_uniqueness_memo_key");
const creating = @import("generated_uniqueness_memo_create");
const State = @typeInfo(@typeInfo(@TypeOf(creating.executeState)).@"fn".return_type.?).error_union.payload;
const Parameter = @typeInfo(@TypeOf(encoding.executeState)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Self = @This();

state: State,
pub fn init() Self {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const state = creating.executeState(empty.allocator(), {}) catch unreachable;

    return .{ .state = state };
}

pub fn key(self: *Self, allocator: std.mem.Allocator, comptime kind: Memo.Kind, summaries: *const Summaries, body: *const Memo.State, normalized: anytype, renewed: @TypeOf(normalized)) std.mem.Allocator.Error!void {
    comptime std.debug.assert(@sizeOf(Level) == @sizeOf(u8) and @alignOf(Level) == @alignOf(u8));

    const output_wants: []const Level = if (kind == .demanded and body.index < summaries.outputs.len) summaries.outputs[body.index] else &.{};
    const Growth = @FieldType(Input, "normalized");

    const input: Input = .{
        .state = self.state,
        .identity = .{ .items = &body.identity, .storage = .plain },
        .index = body.index,
        .kind = @fromBackingInt(@backingInt(kind)),
        .callees = .{ .items = body.callees, .storage = .plain },
        .own_input = .{ .items = std.mem.sliceAsBytes(body.input), .storage = .plain },
        .called_outputs = .{ .items = @ptrCast(summaries.output), .storage = .plain },
        .own_output_wants = .{ .items = std.mem.sliceAsBytes(output_wants), .storage = .plain },
        .called_input_wants = .{ .items = if (kind == .demanded) @ptrCast(summaries.inputs) else &.{}, .storage = .plain },
        .normalized = growth(Growth, normalized),
        .renewed = growth(Growth, renewed),
    };

    self.state = encoding.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);
}

pub fn stateEnd(self: *const Self) usize {
    return @intCast(self.state.state_end);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.state.buffer.items[0..@intCast(self.state.end)];
}

fn growth(comptime Target: type, rows: anytype) Target {
    const values = columns.storage.view(@FieldType(Target, "items"), @as([]const std.meta.Child(@TypeOf(rows)), rows));

    return .{ .items = values, .storage = .owned };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("memo encoding failed: {s}", .{@errorName(err)});
}
