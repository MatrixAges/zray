const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const minimum_indexed_fields = 16;
const minimum_indexed_queries = 8;
const bucket_ratio = 2;

pub const missing_message = "the complete input type does not contain a required field";

pub const Alignment = struct {
    positions: []u64 = &.{},
    scanned: usize = 0,
    length: usize = 0,
};

pub fn publish(allocator: std.mem.Allocator, left: Graph.Fields, right: Graph.Fields, alignment: Alignment) std.mem.Allocator.Error!Graph.Fields {
    if (alignment.length == left.len) return left;

    const result = try left.extend(allocator, alignment.length);
    const names = result.nameColumn();
    const values: []u32 = @ptrCast(result.valueColumn());
    const generated = @import("generated_rx_unification_publish_fields");

    const input: std.meta.Child(generated.Input) = .{
        .names = right.names(),
        .values = @ptrCast(right.values()),
        .positions = alignment.positions,
        .prefix = left.len,
        .target_names = @ptrCast(&names),
        .target_values = @ptrCast(&values),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;

    return result;
}

pub fn alignFields(allocator: std.mem.Allocator, existing: []const []const u8, incoming: []const []const u8, closed: bool) std.mem.Allocator.Error!Alignment {
    const generated = @import("generated_rx_unification_fields");
    const positions = try allocator.alloc(u64, incoming.len);

    errdefer allocator.free(positions);

    const capacity = if (existing.len >= minimum_indexed_fields and incoming.len >= minimum_indexed_queries)
        std.math.ceilPowerOfTwo(usize, std.math.mul(usize, existing.len, bucket_ratio) catch return error.OutOfMemory) catch return error.OutOfMemory

    else
        0;

    const buckets = try allocator.alloc(u64, capacity);

    defer allocator.free(buckets);
    @memset(buckets, 0);

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = generated.executeValue(empty.allocator(), .{
        .existing = .{ .names = existing, .keys = existing, .buckets = @ptrCast(&buckets), .capacity = capacity },
        .incoming = incoming,
        .positions = @ptrCast(&positions),
        .closed = closed,
    }) catch unreachable;

    return .{ .positions = positions, .scanned = @intCast(result.scanned), .length = @intCast(result.length) };
}
