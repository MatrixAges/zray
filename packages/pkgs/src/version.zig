const std = @import("std");
const rules = @import("pkgs_source");

pub fn matches(text: []const u8, version: std.SemanticVersion) error{InvalidRange}!bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = rules.version_matches.executeIn(empty.allocator(), &.{
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

pub fn accepts(range: []const u8, version: []const u8) error{ InvalidRange, InvalidVersion, Overflow }!bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const decision = rules.version_accepts.executeIn(empty.allocator(), &.{
        .range = range,
        .version = version,
        .limit = std.math.maxInt(usize),
    }) catch unreachable;

    return switch (decision) {
        .Accepted => true,
        .Rejected => false,
        .InvalidRange => error.InvalidRange,
        .InvalidVersion => error.InvalidVersion,
        .Overflow => error.Overflow,
    };
}
