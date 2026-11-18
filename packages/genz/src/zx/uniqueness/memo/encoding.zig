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
normalized: std.ArrayList(Memo.Normalized) = .empty,
renewed: std.ArrayList(Memo.Renewed) = .empty,
pub fn init() Self {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const state = creating.executeState(empty.allocator(), {}) catch unreachable;

    return .{ .state = state };
}

pub fn key(self: *Self, allocator: std.mem.Allocator, comptime kind: Memo.Kind, summaries: *const Summaries, body: *const Memo.State) std.mem.Allocator.Error!void {
    comptime std.debug.assert(@sizeOf(Level) == @sizeOf(u8) and @alignOf(Level) == @alignOf(u8));

    const output_wants: []const Level = if (kind == .demanded and body.index < summaries.outputs.len) summaries.outputs[body.index] else &.{};

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
        .normalized = try growth(@FieldType(Input, "normalized"), &self.normalized, allocator, body.growth.normalized),
        .renewed = try growth(@FieldType(Input, "renewed"), &self.renewed, allocator, body.growth.renewed),
    };

    self.state = encoding.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);
}

pub fn stateEnd(self: *const Self) usize {
    return @intCast(self.state.state_end);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.state.buffer.items[0..@intCast(self.state.end)];
}

/// Longer lists need writable storage for canonical ordering. The analysis retains its original order.
fn growth(comptime Target: type, scratch: anytype, allocator: std.mem.Allocator, rows: anytype) std.mem.Allocator.Error!Target {
    const Items = @FieldType(Target, "items");

    if (rows.len < 2) return .{ .items = columns.storage.view(Items, rows), .storage = .plain };
    try scratch.resize(allocator, rows.len);

    @memcpy(scratch.items, rows);

    return .{ .items = columns.storage.view(Items, @as(@TypeOf(rows), scratch.items)), .storage = .owned };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("memo encoding failed: {s}", .{@errorName(err)});
}
