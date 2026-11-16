const std = @import("std");
const bytes = @import("zx").bytes;
const generated = @import("parser_options").generated_parser;

pub const Columns = struct { paths: []const []const u8 = &.{}, texts: []const []const u8 = &.{} };

/// Compare paths and exact XML bytes without allocating columns for the entire incoming request.
pub fn same(previous: Columns, incoming: anytype) bool {
    if (previous.paths.len != incoming.len) return false;

    if (comptime generated) {
        const rule = @import("generated_input_parsed_same");
        const memory = @import("zxc_standard").memory;
        const paths = memory.borrowTextColumn("path", incoming);
        const texts = memory.borrowTextColumn("source", incoming);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), &.{
            .paths = previous.paths,
            .texts = previous.texts,
            .incoming_paths = @ptrCast(&paths),
            .incoming_texts = @ptrCast(&texts),
        }) catch unreachable;
    }

    for (previous.paths, previous.texts, incoming) |path, text, item| {
        if (!bytes.equal(path, item.path) or !bytes.equal(text, item.source)) return false;
    }

    return true;
}
