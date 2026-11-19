const std = @import("std");
const zx = @import("zx");

pub fn select(before: anytype, sources: anytype, positions: ?[]u64) bool {
    if (comptime !@import("parser_options").generated_parser) return seed(before, sources, positions);

    const rule = @import("generated_input_module_versions");
    const previous_paths = zx.memory.borrowReferencedTextColumn("path", before);
    const previous_texts = zx.memory.borrowReferencedTextPath(&.{ "parsed", "xml", "source" }, before);
    const paths = zx.memory.borrowTextColumn("path", sources);
    const texts = zx.memory.borrowTextColumn("source", sources);

    const input: std.meta.Child(rule.Input) = .{
        .prior = &.{ .paths = @ptrCast(&previous_paths), .texts = @ptrCast(&previous_texts), .count = before.len },
        .current = &.{ .paths = @ptrCast(&paths), .texts = @ptrCast(&texts), .count = sources.len },
        .positions = if (positions) |*rows| @ptrCast(rows) else null,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}

fn seed(before: anytype, sources: anytype, positions: ?[]u64) bool {
    if (positions) |rows| {
        var first: usize = 0;

        for (sources, rows) |source, *row| {
            while (first < before.len and std.mem.order(u8, before[first].path, source.path) == .lt) first += 1;

            row.* = if (first < before.len and zx.bytes.equal(before[first].path, source.path) and zx.bytes.equal(before[first].parsed.xml.source, source.source)) first + 1 else 0;
        }

        return true;
    }

    if (before.len != sources.len) return false;

    for (before, sources) |previous, source| {
        if (!zx.bytes.equal(previous.path, source.path) or !zx.bytes.equal(previous.parsed.xml.source, source.source)) return false;
    }

    return true;
}
