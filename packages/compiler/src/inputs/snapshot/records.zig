const std = @import("std");
const zx = @import("zx");
const snapshot = @import("../snapshot.zig");
const memory = zx.memory;

pub fn measure(facts: []const snapshot.Observation) ?usize {
    const rule = @import("generated_input_records_measure");
    const paths = memory.borrowTextColumn("path", facts);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const size = rule.executeValue(empty.allocator(), &.{
        .paths = @ptrCast(&paths),
        .count = facts.len,
    }) catch unreachable;

    return @intCast(size orelse return null);
}
