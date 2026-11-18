const std = @import("std");
const memory = @import("memory");
const traversal = @import("pkgs_source").dependency_graph;
const depth_limit = 256;
const Input = @typeInfo(traversal.Input).pointer.child;
const Result = @typeInfo(@TypeOf(traversal.executeValue(undefined, undefined))).error_union.payload;

pub const Frames = struct {
    node_storage: [depth_limit]u64 = undefined,
    cursor_storage: [depth_limit]u64 = undefined,
    nodes: []u64 = undefined,
    cursors: []u64 = undefined,
    pub fn input(self: *Frames, targets: *const memory.ListColumn, marks: *const []u8, heights: *const []u8, ranked: bool) Input {
        self.nodes = &self.node_storage;
        self.cursors = &self.cursor_storage;

        return .{
            .targets = @ptrCast(targets),
            .count = marks.len,
            .limit = depth_limit,
            .ranked = ranked,
            .marks = @ptrCast(marks),
            .heights = @ptrCast(heights),
            .nodes = @ptrCast(&self.nodes),
            .cursors = @ptrCast(&self.cursors),
        };
    }
};

const Mode = enum { workspace, lock };

pub fn prepare(storage: []u8, packages: anytype, comptime mode: Mode) void {
    if (mode == .lock) {
        for (packages, storage[0..packages.len]) |package, *mark| mark.* = @intFromBool(package.source == .workspace);

        @memset(storage[packages.len..], 0);
    } else {
        @memset(storage, @intFromBool(true));
    }
}

pub fn check(allocator: std.mem.Allocator, packages: anytype, comptime mode: Mode) !Result {
    const storage = try allocator.alloc(u8, if (mode == .lock) 2 * packages.len else packages.len);

    defer allocator.free(storage);
    prepare(storage, packages, mode);

    const marks = storage[0..packages.len];
    const heights = storage[packages.len..];
    const targets = memory.borrowListColumn(usize, "dependencies", "target", packages);
    var frames: Frames = .{};
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const input = frames.input(&targets, &marks, &heights, mode == .lock);

    return traversal.executeValue(empty.allocator(), &input) catch unreachable;
}
