const std = @import("std");
const History = @import("../history.zig");
const memory = @import("zx").memory;
const project = @import("frontend").project;

pub fn publishSource(cache: *const project.ParseCache, paths: []const []const u8, sources: []const project.Source, retained: ?*const History.Retained, target: History.SourceDigests) void {
    if (comptime @import("rx_options").generated_graph) {
        return writeSource(cache, paths, sources, retained, target);
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

fn writeRows(target: History.SourceDigests, rows: anytype) void {
    for (rows, 0..) |row, index| {
        target.present[index] = row.present;

        if (row.present) @memcpy(std.mem.asBytes(&target.words[index]), row.bytes);
    }
}

fn writeSource(cache: *const project.ParseCache, paths: []const []const u8, sources: []const project.Source, retained: ?*const History.Retained, target: History.SourceDigests) void {
    const rule = @import("generated_rx_history_digest_source");
    const Input = std.meta.Child(rule.Input);
    const Retained = std.meta.Child(@typeInfo(@FieldType(Input, "retained")).optional.child);
    const entries = &cache.entries;
    const digests = memory.borrowReferenceColumn("digest", entries.values.items);
    const current = memory.borrowTextColumn("source", sources);
    const earlier = if (retained) |previous| memory.borrowTextColumn("source", previous.sources) else undefined;

    const borrowed: Retained = if (retained) |previous| .{
        .earlier = @ptrCast(&earlier),
        .current = @ptrCast(&current),
        .data = std.mem.sliceAsBytes(previous.digests.words),
        .present = std.mem.sliceAsBytes(previous.digests.present),
    } else undefined;

    const input: Input = .{
        .cache = &.{
            .keys = entries.keys.items,
            .buckets = @ptrCast(&entries.buckets),
            .capacity = entries.buckets.len,
            .digests = @ptrCast(&digests),
        },
        .paths = paths,
        .width = @sizeOf(std.meta.Elem(@TypeOf(target.words))),
        .retained = if (retained != null) &borrowed else null,
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer arena.deinit();

    var scratch_buf: [4096]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const rows = rule.executeValue(fallback.allocator(), &input) catch unreachable;

    writeRows(target, rows);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer arena.deinit();

    var scratch_buf: [4096]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const rows = rule.executeValue(fallback.allocator(), &.{
        .digests = &.{
            .paths = @ptrCast(&names),
            .count = digests.len,
            .bytes = std.mem.sliceAsBytes(digests),
            .first = @offsetOf(History.Digest, "digest"),
            .stride = @sizeOf(History.Digest),
        },
        .paths = paths,
        .width = @sizeOf(@FieldType(History.Digest, "digest")),
    }) catch unreachable;

    writeRows(target, rows);
}
