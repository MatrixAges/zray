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
    const count = facts.len;
    const read_count = if (files == null) 0 else count;
    const paths = try allocator.alloc([]const u8, count);
    const inodes = try allocator.alloc(u64, count);
    const sizes = try allocator.alloc(u64, count);
    const mtime_high = try allocator.alloc(i64, count);
    const mtime_low = try allocator.alloc(u32, count);
    const ctime_high = try allocator.alloc(i64, count);
    const ctime_low = try allocator.alloc(u32, count);
    const read_high = try allocator.alloc(i64, read_count);
    const read_low = try allocator.alloc(u32, read_count);

    for (facts, 0..) |fact, index| {
        const version = if (files) |cache| cache.version(fact.key) orelse return null else null;
        const selected = if (version) |value| Fact.init(fact.path, fact.key, value.metadata) else fact;

        paths[index] = selected.path;
        inodes[index] = selected.inode;
        sizes[index] = selected.size;
        mtime_high[index] = selected.mtime_high;
        mtime_low[index] = selected.mtime_low;
        ctime_high[index] = selected.ctime_high;
        ctime_low[index] = selected.ctime_low;

        if (version) |value| {
            const parts = source.timestamp(value.read);

            read_low[index] = parts.low;
            read_high[index] = parts.high;
        }
    }

    return .{
        .paths = paths,
        .inodes = inodes,
        .sizes = sizes,
        .mtime_high = mtime_high,
        .mtime_low = mtime_low,
        .ctime_high = ctime_high,
        .ctime_low = ctime_low,
        .read_high = read_high,
        .read_low = read_low,
    };
}
