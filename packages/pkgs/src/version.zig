const std = @import("std");
const rule = @import("pkgs_source").version_matches;

pub fn matches(text: []const u8, version: std.SemanticVersion) error{InvalidRange}!bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = rule.executeIn(empty.allocator(), &.{
        .text = text,
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
        .pre = version.pre orelse "",
        .prerelease = version.pre != null,
        .limit = std.math.maxInt(usize),
    }) catch unreachable;

    return result orelse error.InvalidRange;
}
