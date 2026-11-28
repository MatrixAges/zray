const std = @import("std");
const Storage = @import("zx").ir.FunctionStorage;
const generated = @import("generated_column_lengths_publish");

pub fn publish(target: *Storage, count: u64) void {
    if (count == 0) return;

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const published = generated.executeIn(scratch.allocator(), &.{ .first = target.count(), .count = count }) catch unreachable;

    inline for (@typeInfo(Storage).@"struct".field_names) |field| {
        const column = &@field(target, field);

        column.items = column.allocatedSlice()[0..@intCast(published)];
    }
}
