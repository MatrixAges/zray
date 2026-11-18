const std = @import("std");
const rules = @import("pkgs_source");

pub fn validName(name: []const u8) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rules.package_name.executeIn(empty.allocator(), name) catch unreachable;
}

pub fn validateArchive(archive: []const u8, digest: []const u8, lowercase: bool) !void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const status = rules.archive_metadata.executeIn(empty.allocator(), &.{ .archive = archive, .digest = digest, .lowercase = lowercase }) catch unreachable;

    switch (status) {
        .Valid => {},
        .InvalidArchiveSource => return error.InvalidArchiveSource,
        .InvalidArchiveDigest => return error.InvalidArchiveDigest,
    }
}
