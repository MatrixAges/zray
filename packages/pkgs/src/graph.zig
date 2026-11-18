const std = @import("std");
const memory = @import("memory");
const traversal = @import("pkgs_source").dependency_graph;
const depth_limit = 256;
const Mode = enum { workspace, lock };
const Result = @typeInfo(@TypeOf(traversal.executeValue(undefined, undefined))).error_union.payload;

pub fn check(allocator: std.mem.Allocator, packages: anytype, comptime mode: Mode) !Result {
    const count = packages.len;
    const storage = try allocator.alloc(u8, if (mode == .lock) 2 * count else count);

    defer allocator.free(storage);

    const marks = storage[0..count];
    const heights = storage[count..];

    if (mode == .lock) {
        for (packages, marks) |package, *mark| mark.* = @intFromBool(package.source == .workspace);

        @memset(heights, 0);
    } else {
        @memset(marks, @intFromBool(true));
    }

    var node_storage: [depth_limit]u64 = undefined;
    var cursor_storage: [depth_limit]u64 = undefined;
    const nodes: []u64 = &node_storage;
    const cursors: []u64 = &cursor_storage;
    const targets = memory.borrowListColumn(usize, "dependencies", "target", packages);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return traversal.executeValue(empty.allocator(), &.{
        .targets = @ptrCast(&targets),
        .count = count,
        .limit = depth_limit,
        .ranked = mode == .lock,
        .marks = @ptrCast(&marks),
        .heights = @ptrCast(&heights),
        .nodes = @ptrCast(&nodes),
        .cursors = @ptrCast(&cursors),
    }) catch unreachable;
}
