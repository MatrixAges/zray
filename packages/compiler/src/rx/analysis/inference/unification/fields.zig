const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const align_rule = @import("generated_rx_prepare_field_alignment");
const Align = std.meta.Child(align_rule.Input);
const merge_rule = @import("generated_rx_merge_field_columns");
const Merge = std.meta.Child(merge_rule.Input);
pub const missing_message = "the complete input type does not contain a required field";

pub const Alignment = struct {
    positions: []u64 = &.{},
    scanned: usize = 0,
    length: usize = 0,
};

pub fn alignFields(allocator: std.mem.Allocator, existing: []const []const u8, incoming: []const []const u8, closed: bool) std.mem.Allocator.Error!Alignment {
    const input: Align = .{
        .existing = existing,
        .incoming = incoming,
        .closed = closed,
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
    const layout = Graph.Fields.layout(left);

    const input: Merge = .{
        .names = right.names(),
        .values = @ptrCast(right.values()),
        .positions = alignment.positions,
        .prefix = layout.prefix,
        .length = alignment.length,
        .capacity = layout.capacity,
        .published = layout.published,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch_buf: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const result = zx.columns.invoke(merge_rule.executeValue, scratch.allocator(), &input) catch |err| return allocationError(err);

    if (alignment.length == left.len) return left;

    const capacity = if (result.capacity) |size| std.math.cast(usize, size) orelse return error.OutOfMemory else null;
    const next = try Graph.Fields.grow(buffers, allocator, left, alignment.length, capacity);

    for (result.additions) |item| {
        next.set(@intCast(item.position), item.name, @fromBackingInt(item.value));
    }

    return next;
}

fn allocationError(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
