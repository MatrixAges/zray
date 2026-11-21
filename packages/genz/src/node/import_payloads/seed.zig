const std = @import("std");
const transfer = @import("zx").memory.column_transfer;

pub fn append(allocator: std.mem.Allocator, target: anytype, tags: anytype, offsets: []const u32, counts: []const u32, groups: transfer.Groups, bases: []u32, comptime selected: bool) std.mem.Allocator.Error!void {
    if (selected) {
        for (tags, offsets) |tag, source| {
            const group = @backingInt(tag);

            if (!transfer.copy(&allocator, &groups, group, source, 1)) return error.OutOfMemory;

            transfer.publish(&groups, group, 1);
            target.tags.appendAssumeCapacity(tag);
            target.offsets.appendAssumeCapacity(bases[group]);

            bases[group] += 1;
        }

        return;
    }

    for (counts, 0..) |count, group| {
        if (!transfer.copy(&allocator, &groups, group, 0, count)) {
            for (counts[0..group], 0..) |size, done| {
                transfer.discard(&allocator, &groups, done, size);
            }

            return error.OutOfMemory;
        }
    }

    for (counts, 0..) |count, group| transfer.publish(&groups, group, count);

    for (tags, offsets) |tag, offset| {
        target.tags.appendAssumeCapacity(tag);
        target.offsets.appendAssumeCapacity(bases[@backingInt(tag)] + offset);
    }
}
