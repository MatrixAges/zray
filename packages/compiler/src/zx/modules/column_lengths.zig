const std = @import("std");
const memory = @import("zx").memory;
const generated = @import("generated_column_lengths_publish");

pub fn publish(target: *const memory.ColumnLengths, count: u64) void {
    if (count == 0) return;

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    generated.executeIn(scratch.allocator(), &.{ .target = @ptrCast(target), .count = count }) catch unreachable;
}
