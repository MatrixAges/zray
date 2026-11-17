const std = @import("std");
const zx = @import("zx");
const generated = @import("generated_parse_cache_batch");

pub fn classify(entries: anytype, requests: anytype, first: usize, hits: []u64, digests: anytype, scratch: []u8) std.mem.Allocator.Error!void {
    const memory = zx.memory;

    const paths = if (comptime @hasField(@TypeOf(requests), "paths"))
        memory.borrowTextSlice(requests.paths)

    else
        memory.borrowTextColumn("path", requests.items);

    const sources = memory.borrowTextColumn("source", if (comptime @hasField(@TypeOf(requests), "sources")) requests.sources else requests.items);
    const texts = memory.borrowReferenceColumn("text", entries.values.items);
    const stored = memory.borrowReferenceColumn("digest", entries.values.items);
    const digest_bytes = std.mem.sliceAsBytes(digests);

    const input: std.meta.Child(generated.Input) = .{
        .cache = &.{
            .keys = entries.keys.items,
            .buckets = @ptrCast(&entries.buckets),
            .capacity = entries.buckets.len,
            .texts = @ptrCast(&texts),
            .digests = @ptrCast(&stored),
        },
        .paths = @ptrCast(&paths),
        .sources = @ptrCast(&sources),
        .first = first,
        .count = hits.len,
        .hits = @ptrCast(&hits),
        .digests = @ptrCast(&digest_bytes),
        .digest_width = @sizeOf(std.meta.Child(@TypeOf(digests))),
    };

    var fixed = std.heap.FixedBufferAllocator.init(scratch);

    zx.columns.invoke(generated.executeValue, fixed.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
