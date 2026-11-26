const std = @import("std");
const Storage = @import("storage.zig");
const stored = @import("stored.zig");
const Error = std.mem.Allocator.Error;

pub fn append(storage: *Storage, allocator: std.mem.Allocator, comptime field: []const u8, values: anytype) Error!u32 {
    const table = &@field(storage, field);
    const start = std.math.cast(u32, table.tags.items.len) orelse return error.OutOfMemory;

    for (values) |raw| {
        const value = try stored.copy(storage, allocator, raw);
        const header = try table.prepare(allocator, value);

        table.tags.appendAssumeCapacity(header.tag);
        table.offsets.appendAssumeCapacity(header.offset);
    }

    return start;
}
