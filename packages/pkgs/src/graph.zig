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

const assembly = @import("pkgs_source").workspace_graph;
const AssemblyResult = @typeInfo(@TypeOf(assembly.executeValue(undefined, undefined))).error_union.payload;

pub fn assemble(allocator: std.mem.Allocator, root: []const u8, packages: anytype, edges: anytype, capacity: u64) error{OutOfMemory}!AssemblyResult {
    const manifests = @import("workspace/manifest.zig").Manifests.borrow(&.{"manifest"}, packages);
    const paths = memory.borrowTextColumn("path", packages);
    const keys = memory.borrowTextColumn("name", edges);
    const names = memory.borrowWriteColumn([]const u8, "name", edges);
    const targets = memory.borrowWriteColumn(usize, "target", edges);
    const development = memory.borrowWriteColumn(bool, "development", edges);
    const adjacency = memory.borrowListColumn(usize, "dependencies", "target", packages);
    var temporary: std.heap.ArenaAllocator = .init(allocator);

    defer temporary.deinit();

    const scratch = temporary.allocator();
    const buckets = try scratch.alloc(u64, @intCast(capacity));

    @memset(buckets, 0);

    const marks = try scratch.alloc(u8, packages.len);

    @memset(marks, 1);

    const heights = marks[marks.len..];

    const portable_root = if (comptime std.fs.path.sep == '/') root else path: {
        const native = try std.fs.path.resolve(scratch, &.{root});

        std.mem.replaceScalar(u8, native, std.fs.path.sep, '/');

        break :path native;
    };

    var frames: Frames = .{};
    const traversal_input = frames.input(&adjacency, &marks, &heights, false);

    return assembly.executeValue(scratch, &.{
        .manifests = &manifests.input(),
        .paths = @ptrCast(&paths),
        .root = portable_root,
        .count = packages.len,
        .limit = std.math.maxInt(usize),
        .index = &.{ .keys = @ptrCast(&keys), .buckets = @ptrCast(&buckets), .capacity = capacity },
        .output = &.{ .names = @ptrCast(&names), .targets = @ptrCast(&targets), .development = @ptrCast(&development) },
        .graph = &traversal_input,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
