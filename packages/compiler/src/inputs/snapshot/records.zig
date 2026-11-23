const std = @import("std");
const zx = @import("zx");
const snapshot = @import("../snapshot.zig");
const memory = zx.memory;
const Digest = @import("../fingerprint.zig").Digest;

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

pub fn reuse(payload: []const u8, context: []const u8, facts: []const snapshot.Observation, now: snapshot.Time) ?Digest {
    const rule = @import("generated_input_records_read");

    const observations = memory.borrowReadFields(.{
        .paths = "path",
        .inodes = "inode",
        .sizes = "size",
        .mtime_high = "mtime_high",
        .mtime_low = "mtime_low",
        .ctime_high = "ctime_high",
        .ctime_low = "ctime_low",
    }, facts);

    const Shape = std.meta.Child(@FieldType(std.meta.Child(rule.Input), "observed"));
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const digest = rule.executeValue(empty.allocator(), &.{
        .payload = payload,
        .context = context,
        .now = &.{ .high = now.high, .low = now.low },
        .observed = &observations.bind(Shape),
    }) catch return null;

    return (digest orelse return null)[0..@sizeOf(Digest)].*;
}
