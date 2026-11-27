const std = @import("std");
const bytes = @import("zx").bytes;
const versions = @import("../module_versions.zig");

pub fn prepare(allocator: std.mem.Allocator, before: anytype, sources: anytype, previous_packages: ?*const [32]u8, packages: *const [32]u8) !versions.Plan {
    var prefix: usize = 0;

    if (previous_packages) |hash| {
        if (before.len == sources.len and bytes.equal(hash, packages)) {
            while (prefix < sources.len and same(before[prefix], sources[prefix])) : (prefix += 1) {}
            if (prefix == sources.len) return .{ .whole = true, .prefix = prefix, .tail = &.{} };
        }
    }

    if (before.len == 0) return .{ .whole = false, .prefix = 0, .tail = &.{} };

    const tail = try allocator.alloc(u64, sources.len - prefix);
    var first = prefix -| 1;

    for (sources[prefix..], tail) |source, *position| {
        while (first < before.len and std.mem.order(u8, before[first].path, source.path) == .lt) first += 1;

        position.* = if (first < before.len and same(before[first], source)) first + 1 else 0;
    }

    return .{ .whole = false, .prefix = prefix, .tail = tail };
}

fn same(previous: anytype, source: anytype) bool {
    return bytes.equal(previous.path, source.path) and bytes.equal(previous.parsed.xml.source, source.source);
}

pub fn transition(operation: versions.Operation, pending: bool, already_current: bool) versions.Transition {
    if (operation == .Publish) return .{
        .next = if (pending) .Pending else .Current,
        .drop_current = pending,
        .drop_pending = false,
        .retain = true,
    };

    const restore = operation == .Restore and !already_current;

    return .{
        .next = if (restore) .Previous else .Current,
        .drop_current = restore,
        .drop_pending = pending,
        .retain = restore,
    };
}
