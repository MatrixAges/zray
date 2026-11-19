const std = @import("std");
const Record = @import("../darwin.zig").Record;
const DecodeError = error{InvalidDirectoryRecord};
pub const bitmap_count = 5;
pub const buffer_size = 32 * 1024;
pub const batch_size = 16;
pub const common_request = 0x82000c09;
pub const data_length = 0x200;
pub const unknown_kind = 0;
pub const regular_kind = 1;
pub const directory_kind = 2;
pub const link_kind = 3;
const metadata_attributes = 0x02000c08;
const object_type = 0x8;

pub fn decode(buffer: []const u8, offset: usize, rows: []Record, endian: std.builtin.Endian) DecodeError!usize {
    var next = offset;

    for (rows) |*row| {
        const length = try read(u32, buffer, next, endian);

        if (length > buffer.len - next) return error.InvalidDirectoryRecord;

        const record = buffer[next..][0..length];
        const common = try read(u32, record, 4, endian);
        const file = try read(u32, record, 16, endian);
        const name_start = 24 + @as(usize, try read(u32, record, 24, endian));
        const name_length = try read(u32, record, 28, endian);

        if (name_start > record.len or name_length == 0 or name_length > record.len - name_start) return error.InvalidDirectoryRecord;

        row.name = record[name_start..][0 .. name_length - 1];

        row.kind = if (common & object_type == 0) unknown_kind else switch (try read(u32, record, 32, endian)) {
            1 => regular_kind,
            2 => directory_kind,
            5 => link_kind,
            else => unknown_kind,
        };

        row.has_metadata = common & metadata_attributes == metadata_attributes and file & data_length != 0;

        if (row.has_metadata) {
            row.modified_seconds = try read(u64, record, 36, endian);
            row.modified_nanos = try read(u64, record, 44, endian);
            row.changed_seconds = try read(u64, record, 52, endian);
            row.changed_nanos = try read(u64, record, 60, endian);
            row.inode = try read(u64, record, 68, endian);
            row.size = try read(u64, record, 76, endian);
        }

        next += length;
    }

    return next;
}

fn read(comptime T: type, record: []const u8, offset: usize, endian: std.builtin.Endian) DecodeError!T {
    const width = @sizeOf(T);

    if (offset > record.len or width > record.len - offset) return error.InvalidDirectoryRecord;

    return std.mem.readInt(T, record[offset..][0..width], endian);
}
