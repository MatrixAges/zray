const std = @import("std");
const rules = @import("cli_source").archive_path;

pub fn normalize(name: []const u8, directory: bool) error{InvalidPackageArchivePath}![]const u8 {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const bounds = rules.executeValue(empty.allocator(), &.{ .name = name, .directory = directory }) catch unreachable;

    if (!bounds.valid) return error.InvalidPackageArchivePath;

    return name[@intCast(bounds.start)..@intCast(bounds.end)];
}
