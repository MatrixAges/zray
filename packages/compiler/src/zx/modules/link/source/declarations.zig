const std = @import("std");
const zx = @import("zx");
const rule = @import("generated_source_link_declarations");

pub fn contains(rows: anytype, prefix: usize) bool {
    if (rows.len == 0) return true;
    if (prefix == 0) return false;

    const Row = std.meta.Elem(@TypeOf(rows));

    comptime std.debug.assert(@typeInfo(@FieldType(Row, "type_id")).@"enum".tag_type == u32);

    const input: std.meta.Child(rule.Input) = .{
        .rows = std.mem.sliceAsBytes(rows),
        .count = rows.len,
        .stride = @sizeOf(Row),
        .offset = @offsetOf(Row, "type_id"),
        .prefix = prefix,
        .little_endian = @import("builtin").target.cpu.arch.endian() == .little,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
}
