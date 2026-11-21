const std = @import("std");
const Memo = @import("../memo.zig");
const Summaries = @import("../summaries.zig");
const Rows = @import("body_rows.zig");
const zx = @import("zx");
const encoding = @import("generated_uniqueness_memo_key");
const Parameter = @typeInfo(@TypeOf(encoding.executeState)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const State = @FieldType(Input, "state");
const Self = @This();

buffer: zx.memory.ByteWriter,
state_end: u64 = 0,
order: zx.memory.U32Scratch,
pub fn init(backing: std.mem.Allocator) Self {
    return .{ .buffer = .{ .allocator = backing }, .order = .{ .allocator = backing } };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
    self.order.deinit();
}

pub fn binding(self: *Self) State {
    return .{ .buffer = @ptrCast(&self.buffer), .state_end = self.state_end };
}

pub fn probe(self: *Self, allocator: std.mem.Allocator, comptime kind: Memo.Kind, summaries: *const Summaries, rows: *const Rows, body: usize, table: anytype, digest: *Memo.Digest) std.mem.Allocator.Error!?u32 {
    const Table = std.meta.Child(@FieldType(Input, "table"));
    const Body = std.meta.Child(@FieldType(Input, "rows"));
    var views: Rows.Views(Body) = undefined;
    const target: []u8 = digest;
    const used = table.useColumn();

    const input: Input = .{
        .state = self.binding(),
        .rows = &rows.view(Body, &views),
        .summaries = &Rows.summaries(std.meta.Child(@FieldType(Input, "summaries")), summaries),
        .index = body,
        .kind = @fromBackingInt(@backingInt(kind)),
        .order = &.{ .indices = @ptrCast(&self.order.items), .scratch = @ptrCast(&self.order) },
        .digest = @ptrCast(&target),
        .table = &table.probe(Table, &used),
    };

    const result = encoding.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);

    self.state_end = result.state.state_end;

    return result.row;
}

pub fn stateEnd(self: *const Self) usize {
    return @intCast(self.state_end);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.buffer.buffer.items;
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("memo encoding failed: {s}", .{@errorName(err)});
}
