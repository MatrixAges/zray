const std = @import("std");
const inputs = @import("../collection.zig");

pub fn find(comptime field: []const u8, path: []const u8, candidates: anytype) ?usize {
    if (comptime std.mem.eql(u8, field, "key")) {
        if (inputs.kind(path) != .ZX) return null;
    }

    for (candidates, 0..) |candidate, index| {
        if (std.mem.eql(u8, @field(candidate, field), path)) return index;
    }

    return null;
}

pub fn register(allocator: std.mem.Allocator, declarations: anytype, sources: anytype, jobs: anytype) !usize {
    var count: usize = 0;

    for (declarations) |entry| count += @intFromBool(entry.specifier != null);

    var external: usize = 0;
    var internal = count;

    for (declarations, jobs) |entry, *job| {
        job.source = find("path", entry.path, sources);

        if (entry.specifier) |specifier| {
            job.binding = external;
            job.name = specifier;
            external += 1;
        } else {
            job.binding = internal;
            job.name = try std.mem.concat(allocator, u8, &.{ "zig:", entry.module });
            internal += 1;
        }
    }

    return count;
}
