const std = @import("std");
const History = @import("../history.zig");
const memory = @import("zxc_standard").memory;

pub fn publish(digests: []const History.Digest, paths: []const []const u8, target: History.SourceDigests) void {
    if (paths.len == 0) return;

    if (digests.len == 0) {
        @memset(target.present, false);

        return;
    }

    const rule = @import("generated_rx_history_digest_publish");
    const names = memory.borrowTextColumn("path", digests);
    const data = std.mem.sliceAsBytes(target.words);
    const present = std.mem.sliceAsBytes(target.present);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeValue(empty.allocator(), &.{
        .digests = &.{
            .paths = @ptrCast(&names),
            .count = digests.len,
            .bytes = std.mem.sliceAsBytes(digests),
            .first = @offsetOf(History.Digest, "digest"),
            .stride = @sizeOf(History.Digest),
        },
        .paths = paths,
        .width = @sizeOf(@FieldType(History.Digest, "digest")),
        .data = @ptrCast(&data),
        .present = @ptrCast(&present),
    }) catch unreachable;
}
