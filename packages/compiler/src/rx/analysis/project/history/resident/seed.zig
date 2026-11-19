const std = @import("std");
const Digest = @import("../../history.zig").Digest;
const Source = @import("frontend").project.Source;
const bytes = @import("zx").bytes;

pub fn select(comptime Selection: type, epochs: anytype, frame: *const [32]u8, shape: *const [32]u8, digests: []const Digest, sources: []const Source) Selection {
    const latest = &epochs[epochs.len - 1];

    if (!bytes.equal(&latest.snapshot.shape, shape) or !samePaths(latest.rx_digests, digests) or !sameSources(latest.snapshot.sources, sources)) {
        return .{ .parent_count = epochs.len };
    }

    var before = epochs.len;
    var parent = before;

    while (before > 1) {
        before -= 1;
        const edits = epochs[before].edited_rx orelse break;

        if (overlaps(edits, latest.rx_digests, digests)) parent = before;
    }

    return .{ .parent_count = parent, .rx_only = true, .same_input = bytes.equal(&epochs[parent - 1].snapshot.frame, frame) };
}

fn samePaths(previous: []const Digest, current: []const Digest) bool {
    if (previous.len != current.len) return false;

    for (previous, current) |*before, *after| {
        if (!bytes.equal(before.path, after.path)) return false;
    }

    return true;
}

/// Returns the rows whose source changed, for snapshots over the same ordered paths.
pub fn changes(allocator: std.mem.Allocator, previous: []const Digest, current: []const Digest) std.mem.Allocator.Error![]const u64 {
    var rows: std.ArrayList(u64) = .empty;

    for (previous, current, 0..) |*before, *after, row| {
        if (!bytes.equal(&before.digest, &after.digest)) try rows.append(allocator, row);
    }

    return rows.items;
}

fn overlaps(rows: []const u64, previous: []const Digest, current: []const Digest) bool {
    for (rows) |row| {
        if (!bytes.equal(&previous[@intCast(row)].digest, &current[@intCast(row)].digest)) return true;
    }

    return false;
}

fn sameSources(previous: []const Source, current: []const Source) bool {
    if (previous.len != current.len) return false;

    for (previous, current) |*before, *after| {
        if (!bytes.equal(before.path, after.path) or !bytes.equal(before.source, after.source)) return false;
    }

    return true;
}
