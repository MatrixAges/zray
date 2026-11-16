const std = @import("std");
const History = @import("../history.zig");
const memory = @import("zx").memory;
const project = @import("frontend").project;

pub fn publishSource(cache: *const project.ParseCache, paths: []const []const u8, sources: []const project.Source, retained: ?*const History.Retained, target: History.SourceDigests) void {
    if (comptime @import("rx_options").generated_graph) {
        if (retained) |previous| {
            copyUnchanged(cache, paths, sources, previous, target);

            return;
        }
    }

    for (paths, sources, 0..) |path, source, index| {
        if (retained) |previous| {
            if (@import("zx").bytes.equal(previous.sources[index].source, source.source)) {
                target.set(index, previous.digests.at(index));

                continue;
            }
        }

        setFromCache(cache, path, target, index);
    }
}

fn copyUnchanged(cache: *const project.ParseCache, paths: []const []const u8, sources: []const project.Source, previous: *const History.Retained, target: History.SourceDigests) void {
    const rule = @import("generated_rx_history_digest_retain");
    const earlier = memory.borrowTextColumn("source", previous.sources);
    const current = memory.borrowTextColumn("source", sources);
    const data = std.mem.sliceAsBytes(target.words);
    const present = std.mem.sliceAsBytes(target.present);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    var input: std.meta.Child(rule.Input) = .{
        .earlier = @ptrCast(&earlier),
        .current = @ptrCast(&current),
        .previous_data = std.mem.sliceAsBytes(previous.digests.words),
        .previous_present = std.mem.sliceAsBytes(previous.digests.present),
        .data = @ptrCast(&data),
        .present = @ptrCast(&present),
        .width = @sizeOf(std.meta.Elem(@TypeOf(target.words))),
        .start = 0,
        .end = paths.len,
    };

    while (input.start < input.end) {
        const next: usize = @intCast(rule.executeValue(scratch.allocator(), &input) catch unreachable);

        if (next == paths.len) return;

        setFromCache(cache, paths[next], target, next);

        input.start = next + 1;
    }
}

fn setFromCache(cache: *const project.ParseCache, path: []const u8, target: History.SourceDigests, index: usize) void {
    const digest = cache.sourceDigest(path);

    target.set(index, if (digest != null) &digest.? else null);
}

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
