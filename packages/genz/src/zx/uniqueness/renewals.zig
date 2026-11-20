const std = @import("std");
const generated = @import("genz_options").generated_analysis;
pub const Record = struct { owner: u32, path: []const u32, value: bool = false, writable: bool = false };

pub const Records = if (generated) struct {
    keys: []const u64 = &.{},
    paths: []const []const u32 = &.{},
} else []const Record;

pub const empty: Records = if (generated) .{} else &.{};

pub fn count(records: Records) usize {
    return if (generated) records.keys.len else records.len;
}

pub fn at(records: Records, index: usize) Record {
    if (!generated) return records[index];

    const slot_bits = @bitSizeOf(u32);
    const group = records.keys[index] >> slot_bits;

    return .{ .owner = @intCast(group >> @bitSizeOf(u1)), .path = records.paths[index], .value = @as(u1, @truncate(group)) != 0, .writable = (records.keys[index] & 1) != 0 };
}

pub fn copySeed(allocator: std.mem.Allocator, source: []const Record) std.mem.Allocator.Error![]const Record {
    if (source.len == 0) return &.{};

    const rows = try allocator.alloc(Record, source.len);
    var copied: usize = 0;

    errdefer {
        for (rows[0..copied]) |row| allocator.free(row.path);

        allocator.free(rows);
    }

    for (source, rows) |row, *target| {
        target.* = .{ .owner = row.owner, .path = try allocator.dupe(u32, row.path), .value = row.value, .writable = row.writable };
        copied += 1;
    }

    return rows;
}
