const std = @import("std");
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

    const rule = @import("generated_input_darwin_decode");
    const Parameter = rule.Input;
    const Input = if (comptime @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer arena.deinit();

    var scratch_bytes: [4096]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_bytes, arena.allocator());

    const input: Input = .{
        .buffer = buffer,
        .offset = offset,
        .count = rows.len,
        .little_endian = endian == .little,
    };

    const decoded = (rule.executeValue(fallback.allocator(), if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch return error.InvalidDirectoryRecord) orelse return error.InvalidDirectoryRecord;

    if (decoded.rows.len != rows.len) return error.InvalidDirectoryRecord;

    for (rows, decoded.rows) |*dst, src| {
        dst.* = .{
            .name = src.name,
            .kind = src.kind,
            .has_metadata = src.has_metadata,
            .inode = src.inode,
            .size = src.size,
            .modified_seconds = src.modified_seconds,
            .modified_nanos = src.modified_nanos,
            .changed_seconds = src.changed_seconds,
            .changed_nanos = src.changed_nanos,
        };
    }

    return @intCast(decoded.offset);
}
