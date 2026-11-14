const std = @import("std");
const bytes = @import("zx").bytes;
const generated = @import("parser_options").generated_parser;
const batch_size = 64;
pub const Columns = struct { paths: []const []const u8 = &.{}, texts: []const []const u8 = &.{} };

/// Compare paths and exact XML bytes without allocating columns for the entire incoming request.
pub fn same(previous: Columns, incoming: anytype) bool {
    if (previous.paths.len != incoming.len) return false;

    if (comptime generated) {
        const rule = @import("generated_input_parsed_same");
        var paths: [batch_size][]const u8 = undefined;
        var texts: [batch_size][]const u8 = undefined;
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        var start: usize = 0;

        while (start < incoming.len) {
            const count = @min(batch_size, incoming.len - start);
            const end = start + count;

            for (incoming[start..end], paths[0..count], texts[0..count]) |item, *path, *text| {
                path.* = item.path;
                text.* = item.source;
            }

            if (!(rule.executeValue(empty.allocator(), &.{
                .paths = previous.paths[start..end],
                .texts = previous.texts[start..end],
                .incoming_paths = paths[0..count],
                .incoming_texts = texts[0..count],
            }) catch unreachable)) return false;

            start = end;
        }

        return true;
    }

    for (previous.paths, previous.texts, incoming) |path, text, item| {
        if (!bytes.equal(path, item.path) or !bytes.equal(text, item.source)) return false;
    }

    return true;
}
