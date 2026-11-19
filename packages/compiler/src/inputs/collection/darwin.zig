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
    const names = memory.borrowWriteColumn([]const u8, "name", rows);
    const kinds = memory.borrowWriteColumn(u8, "kind", rows);
    const present = memory.borrowWriteColumn(bool, "has_metadata", rows);
    const inodes = memory.borrowWriteColumn(u64, "inode", rows);
    const sizes = memory.borrowWriteColumn(u64, "size", rows);
    const modified_seconds = memory.borrowWriteColumn(u64, "modified_seconds", rows);
    const modified_nanos = memory.borrowWriteColumn(u64, "modified_nanos", rows);
    const changed_seconds = memory.borrowWriteColumn(u64, "changed_seconds", rows);
    const changed_nanos = memory.borrowWriteColumn(u64, "changed_nanos", rows);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(rule.Input) = .{
        .buffer = buffer,
        .offset = offset,
        .count = rows.len,
        .little_endian = endian == .little,
        .rows = &.{
            .names = @ptrCast(&names),
            .kinds = @ptrCast(&kinds),
            .has_metadata = @ptrCast(&present),
            .metadata = &.{
                .inode = @ptrCast(&inodes),
                .size = @ptrCast(&sizes),
                .modified_seconds = @ptrCast(&modified_seconds),
                .modified_nanos = @ptrCast(&modified_nanos),
                .changed_seconds = @ptrCast(&changed_seconds),
                .changed_nanos = @ptrCast(&changed_nanos),
            },
        },
    };

    const next = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidDirectoryRecord;

    return @intCast(next orelse return error.InvalidDirectoryRecord);
}
