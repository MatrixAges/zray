const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const align_rule = @import("generated_rx_prepare_field_alignment");
const Align = std.meta.Child(align_rule.Input);
const Scan = std.meta.Child(@FieldType(Align, "scan"));
const Index = std.meta.Child(@FieldType(Scan, "existing"));
const merge_rule = @import("generated_rx_merge_field_columns");
const Merge = std.meta.Child(merge_rule.Input);
pub const missing_message = "the complete input type does not contain a required field";

pub const Alignment = struct {
    positions: []u64 = &.{},
    scanned: usize = 0,
    length: usize = 0,
};

const AlignFrame = struct {
    allocator: std.mem.Allocator,
    buckets: []u64 = &.{},
    index: Index = undefined,
};

pub fn alignFields(allocator: std.mem.Allocator, existing: []const []const u8, incoming: []const []const u8, closed: bool) std.mem.Allocator.Error!Alignment {
    var frame: AlignFrame = .{ .allocator = allocator };

    defer allocator.free(frame.buckets);

    frame.index = .{ .names = existing, .keys = existing, .buckets = @ptrCast(&frame.buckets), .capacity = 0 };

    const input: Align = .{
        .frame = @ptrCast(&frame),
        .scan = &.{ .existing = &frame.index, .incoming = incoming, .closed = closed },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch_buf: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const result = zx.columns.invoke(align_rule.executeValue, scratch.allocator(), &input) catch |err| return allocationError(err);

    return .{
        .positions = try allocator.dupe(u64, result.positions),
        .scanned = @intCast(result.scanned),
        .length = @intCast(result.length),
    };
}

pub fn publish(buffers: *Graph.Fields.Buffers, allocator: std.mem.Allocator, left: Graph.Fields, right: Graph.Fields.View, alignment: Alignment) std.mem.Allocator.Error!Graph.Fields {
    var resize: Graph.Fields.Resize = .{ .buffers = buffers, .allocator = allocator, .fields = left };

    const input: Merge = .{
        .storage = &resize.borrow(std.meta.Child(@FieldType(Merge, "storage"))),
        .columns = &.{
            .names = right.names(),
            .values = @ptrCast(right.values()),
            .positions = alignment.positions,
            .prefix = left.len,
            .target_names = @ptrCast(&resize.names),
            .target_values = @ptrCast(&resize.values),
        },
        .length = alignment.length,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    merge_rule.executeIn(empty.allocator(), &input) catch |err| return allocationError(err);

    return resize.fields;
}

pub fn reserveFieldAlignmentIndex(handle: *anyopaque, minimum: u64) std.mem.Allocator.Error!void {
    const frame: *AlignFrame = @ptrCast(@alignCast(handle));
    const required = std.math.cast(usize, minimum) orelse return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, required) catch return error.OutOfMemory;
    frame.buckets = try frame.allocator.alloc(u64, capacity);
    frame.index.capacity = capacity;
}

fn allocationError(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
