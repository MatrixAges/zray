const std = @import("std");
const inputs = @import("../collection.zig");
const missing = std.math.maxInt(u64);

pub fn locate(comptime field: []const u8, declarations: anytype, candidates: anytype, matches: anytype) void {
    for (declarations, matches) |entry, *match| {
        match.source = missing;

        if (comptime std.mem.eql(u8, field, "key")) {
            if (inputs.kind(entry.path) != .ZX) continue;
        }

        for (candidates, 0..) |candidate, index| {
            if (!std.mem.eql(u8, @field(candidate, field), entry.path)) continue;
            match.source = index;

            break;
        }
    }
}

pub fn register(allocator: std.mem.Allocator, declarations: anytype, sources: anytype, jobs: anytype) !usize {
    locate("path", declarations, sources, jobs);

    var count: usize = 0;

    for (declarations) |entry| count += @intFromBool(entry.specifier != null);

    var external: usize = 0;
    var internal = count;

    for (declarations, jobs) |entry, *job| {
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
