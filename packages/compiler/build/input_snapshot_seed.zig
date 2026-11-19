const std = @import("std");
const source = @import("compiler").input_snapshot;
const Files = @import("resident/files.zig");
const Fact = source.Observation;

pub fn reuse(allocator: std.mem.Allocator, payload: []const u8, context: []const u8, facts: []const Fact, now: source.Time) !?[32]u8 {
    const previous = std.json.parseFromSliceLeaky(source.Snapshot, allocator, payload, .{}) catch return null;
    const observed = (try columns(allocator, facts, null)).?;

    if (!try source.reuse(allocator, .{
        .context = context,
        .current = &observed,
        .previous = &previous,
        .now_high = now.high,
        .now_low = now.low,
        .stored_checksum = "",
        .actual_checksum = "",
    })) return null;

    var digest: [32]u8 = undefined;

    _ = std.fmt.hexToBytes(&digest, previous.fingerprint) catch return null;

    return digest;
}

pub fn encode(allocator: std.mem.Allocator, context: []const u8, facts: []const Fact, files: *const Files, fingerprint: *const [32]u8) !?[]const u8 {
    const contents = try columns(allocator, facts, files) orelse return null;
    const snapshot: source.Snapshot = .{ .context = context, .fingerprint = &std.fmt.bytesToHex(fingerprint, .lower), .files = &contents };

    return try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
}

fn columns(allocator: std.mem.Allocator, facts: []const Fact, files: ?*const Files) !?source.Files {
    var result: source.Files = undefined;

    inline for (@typeInfo(source.Files).@"struct".field_names) |field| {
        const Child = std.meta.Child(@FieldType(source.Files, field));

        @field(result, field) = try allocator.alloc(Child, if (files == null and std.mem.startsWith(u8, field, "read_")) 0 else facts.len);
    }

    for (facts, 0..) |fact, index| {
        const version = if (files) |cache| cache.version(fact.key) orelse return null else null;
        const selected = if (version) |value| Fact.init(fact.path, fact.key, value.metadata) else fact;

        @constCast(result.paths)[index] = selected.path;
        @constCast(result.inodes)[index] = selected.inode;
        @constCast(result.sizes)[index] = selected.size;
        @constCast(result.mtime_high)[index] = selected.mtime_high;
        @constCast(result.mtime_low)[index] = selected.mtime_low;
        @constCast(result.ctime_high)[index] = selected.ctime_high;
        @constCast(result.ctime_low)[index] = selected.ctime_low;

        if (version) |value| timestamp(&result, "read", index, value.read);
    }

    return result;
}

fn timestamp(columns_value: *source.Files, comptime field: []const u8, index: usize, value: i96) void {
    const parts = source.timestamp(value);

    @constCast(@field(columns_value, field ++ "_low"))[index] = parts.low;
    @constCast(@field(columns_value, field ++ "_high"))[index] = parts.high;
}
