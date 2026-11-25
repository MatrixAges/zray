const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const seed = @import("darwin/seed.zig");
pub const settings = if (generated) @import("generated_input_darwin_constants").@"zx.constants" else seed;

pub const Record = struct {
    name: []const u8,
    kind: u8,
    has_metadata: bool,
    inode: u64,
    size: u64,
    modified_seconds: u64,
    modified_nanos: u64,
    changed_seconds: u64,
    changed_nanos: u64,
};

pub fn decode(buffer: []const u8, offset: usize, rows: []Record, endian: std.builtin.Endian) error{InvalidDirectoryRecord}!usize {
    if (comptime !generated) return seed.decode(buffer, offset, rows, endian);

    const memory = zx.memory;
    const rule = @import("generated_input_darwin_decode");
    const Input = std.meta.Child(rule.Input);
    const Rows = std.meta.Child(@FieldType(Input, "rows"));

    var metadata = memory.borrowWriteFields(.{
        .inode = "inode",
        .size = "size",
        .modified_seconds = "modified_seconds",
        .modified_nanos = "modified_nanos",
        .changed_seconds = "changed_seconds",
        .changed_nanos = "changed_nanos",
    }, rows);

    var columns = memory.borrowWriteFields(.{ .names = "name", .kinds = "kind", .has_metadata = "has_metadata" }, rows);
    var measurements = metadata.bind(std.meta.Child(@FieldType(Rows, "metadata")));
    var target: Rows = undefined;

    columns.fill(&target);

    target.metadata = &measurements;

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .buffer = buffer,
        .offset = offset,
        .count = rows.len,
        .little_endian = endian == .little,
        .rows = &target,
    };

    const next = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidDirectoryRecord;

    return @intCast(next orelse return error.InvalidDirectoryRecord);
}
