const compiler = @import("compiler");
const Digest = @import("rx_analysis").project.ModuleDigest;
const Source = compiler.project.Source;
const bytes = compiler.bytes;
pub const Edits = union(enum) { same, single: usize, multiple };

pub fn compare(previous: []const Digest, current: []const Digest) Edits {
    if (previous.len != current.len) return .multiple;

    var edited: ?usize = null;

    for (previous, current, 0..) |*before, *after, row| {
        if (!bytes.equal(before.path, after.path)) return .multiple;
        if (bytes.equal(&before.digest, &after.digest)) continue;
        if (edited != null) return .multiple;

        edited = row;
    }

    return if (edited) |row| .{ .single = row } else .same;
}

pub fn sameSources(previous: []const Source, current: []const Source) bool {
    if (previous.len != current.len) return false;

    for (previous, current) |*before, *after| {
        if (!bytes.equal(before.path, after.path) or !bytes.equal(before.source, after.source)) return false;
    }

    return true;
}
