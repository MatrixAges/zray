const std = @import("std");
const compiler = @import("compiler");
const Digest = @import("rx_analysis").project.ModuleDigest;
const Source = compiler.project.Source;
const bytes = compiler.bytes;

pub fn samePaths(previous: []const Digest, current: []const Digest) bool {
    if (previous.len != current.len) return false;

    for (previous, current) |*before, *after| {
        if (!bytes.equal(before.path, after.path)) return false;
    }

    return true;
}

/// Returns the rows whose source changed, for snapshots over the same ordered paths.
pub fn changed(allocator: std.mem.Allocator, previous: []const Digest, current: []const Digest) std.mem.Allocator.Error![]const usize {
    var rows: std.ArrayList(usize) = .empty;

    for (previous, current, 0..) |*before, *after, row| {
        if (!bytes.equal(&before.digest, &after.digest)) try rows.append(allocator, row);
    }

    return rows.items;
}

pub fn overlaps(rows: []const usize, previous: []const Digest, current: []const Digest) bool {
    for (rows) |row| {
        if (!bytes.equal(&previous[row].digest, &current[row].digest)) return true;
    }

    return false;
}

pub fn sameSources(previous: []const Source, current: []const Source) bool {
    if (previous.len != current.len) return false;

    for (previous, current) |*before, *after| {
        if (!bytes.equal(before.path, after.path) or !bytes.equal(before.source, after.source)) return false;
    }

    return true;
}
