const std = @import("std");

pub fn write(allocator: std.mem.Allocator, target: [][]const u8, text: anytype) std.mem.Allocator.Error!void {
    if (text.borrowed) {
        @memcpy(target, text.values);

        return;
    }

    var initialized: usize = 0;

    errdefer for (target[0..initialized]) |value| allocator.free(value);

    for (target, text.values) |*slot, value| {
        slot.* = try allocator.dupe(u8, value);
        initialized += 1;
    }
}
