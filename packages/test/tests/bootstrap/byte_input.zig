const std = @import("std");
const entry = @import("entry");
pub const Output = entry.Output;

pub fn execute(arena: *std.heap.ArenaAllocator, source: []const u8) @typeInfo(@TypeOf(entry.execute)).@"fn".return_type.? {
    if (comptime entry.Input == []const u8) return entry.execute(arena, source);

    return entry.execute(arena, &.{ .source = source, .placement = null });
}
