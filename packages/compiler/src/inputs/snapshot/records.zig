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
    const views = Views.init(facts);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const digest = rule.executeValue(empty.allocator(), &.{
        .payload = payload,
        .context = context,
        .now = &.{ .high = now.high, .low = now.low },
        .observed = &views.input(std.meta.Child(@FieldType(std.meta.Child(rule.Input), "observed")), facts.len),
    }) catch return null;

    return (digest orelse return null)[0..@sizeOf(Digest)].*;
}

const Views = struct {
    paths: memory.TextColumn,
    inodes: memory.ReadColumn,
    sizes: memory.ReadColumn,
    modified_high: memory.ReadColumn,
    modified_low: memory.ReadColumn,
    changed_high: memory.ReadColumn,
    changed_low: memory.ReadColumn,
    fn init(rows: anytype) Views {
        return .{
            .paths = memory.borrowTextColumn("path", rows),
            .inodes = memory.borrowReadColumn(u64, "inode", rows),
            .sizes = memory.borrowReadColumn(u64, "size", rows),
            .modified_high = memory.borrowReadColumn(i32, "mtime_high", rows),
            .modified_low = memory.borrowReadColumn(u64, "mtime_low", rows),
            .changed_high = memory.borrowReadColumn(i32, "ctime_high", rows),
            .changed_low = memory.borrowReadColumn(u64, "ctime_low", rows),
        };
    }
    fn input(self: *const Views, comptime Shape: type, count: usize) Shape {
        var result: Shape = undefined;
        result.paths = @ptrCast(&self.paths);
        result.inodes = @ptrCast(&self.inodes);
        result.sizes = @ptrCast(&self.sizes);
        result.mtime_high = @ptrCast(&self.modified_high);
        result.mtime_low = @ptrCast(&self.modified_low);
        result.ctime_high = @ptrCast(&self.changed_high);
        result.ctime_low = @ptrCast(&self.changed_low);
        result.count = count;

        return result;
    }
};
