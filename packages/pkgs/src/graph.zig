const std = @import("std");
const memory = @import("memory");
const traversal = @import("pkgs_source").dependency_graph;
pub const depth_limit = 256;
pub const Input = @typeInfo(traversal.Input).pointer.child;
const Result = @typeInfo(@TypeOf(traversal.executeValue(undefined, undefined))).error_union.payload;
const Mode = enum { workspace, lock };

pub fn input(targets: *const memory.ListColumn, initial_marks: []const u8, ranked: bool) Input {
    return .{
        .targets = @ptrCast(targets),
        .count = initial_marks.len,
        .limit = depth_limit,
        .ranked = ranked,
        .initial_marks = initial_marks,
    };
}

pub fn prepare(storage: []u8, packages: anytype, comptime mode: Mode) void {
    if (mode == .lock) {
        for (packages, storage) |package, *mark| mark.* = @intFromBool(package.source == .workspace);
    } else {
        @memset(storage, @intFromBool(true));
    }
}

pub fn check(allocator: std.mem.Allocator, packages: anytype, comptime mode: Mode) !Result {
    const marks = try allocator.alloc(u8, packages.len);

    defer allocator.free(marks);
    prepare(marks, packages, mode);

    const targets = memory.borrowListColumn(usize, "dependencies", "target", packages);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const query = input(&targets, marks, mode == .lock);

    return traversal.executeValue(arena.allocator(), &query);
}

const assembly = @import("pkgs_source").workspace_graph;
const AssemblyResult = @typeInfo(@TypeOf(assembly.executeValue(undefined, undefined))).error_union.payload;

pub fn assemble(allocator: std.mem.Allocator, root: []const u8, packages: anytype, edges: anytype, capacity: u64) error{OutOfMemory}!AssemblyResult {
    const manifests = @import("workspace/manifest.zig").Manifests.borrow(&.{"manifest"}, packages);
    const paths = memory.borrowTextColumn("path", packages);
    const keys = memory.borrowTextColumn("name", edges);
    var names = memory.borrowWriteColumn([]const u8, "name", edges);
    var targets = memory.borrowWriteColumn(usize, "target", edges);
    var development = memory.borrowWriteColumn(bool, "development", edges);
    const adjacency = memory.borrowListColumn(usize, "dependencies", "target", packages);
    var temporary: std.heap.ArenaAllocator = .init(allocator);

    defer temporary.deinit();

    const scratch = temporary.allocator();
    var buckets = try scratch.alloc(u64, @intCast(capacity));

    @memset(buckets, 0);

    const marks = try scratch.alloc(u8, packages.len);

    @memset(marks, 1);

    const portable_root = if (comptime std.fs.path.sep == '/') root else path: {
        const native = try std.fs.path.resolve(scratch, &.{root});

        std.mem.replaceScalar(u8, native, std.fs.path.sep, '/');

        break :path native;
    };

    const traversal_input = input(&adjacency, marks, false);

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
