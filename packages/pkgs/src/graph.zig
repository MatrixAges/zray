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
        .limit = null,
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
    const marks = if (mode == .lock) try allocator.alloc(u8, packages.len) else null;

    defer if (marks) |storage| allocator.free(storage);

    if (marks) |storage| prepare(storage, packages, .lock);

    const targets = memory.borrowListColumn(usize, "dependencies", "target", packages);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const query: Input = .{
        .targets = @ptrCast(&targets),
        .count = packages.len,
        .limit = null,
        .ranked = mode == .lock,
        .initial_marks = marks,
    };

    return traversal.executeValue(arena.allocator(), &query);
}

const assembly = @import("pkgs_source").workspace_graph;
const AssemblyResult = @typeInfo(@TypeOf(assembly.executeValue(undefined, undefined))).error_union.payload;
pub const AssemblyOutcome = struct { owner: u64, edge: u64, status: @FieldType(AssemblyResult, "status") };

pub fn assemble(allocator: std.mem.Allocator, root: []const u8, packages: anytype, edges: anytype, capacity: u64) error{OutOfMemory}!AssemblyOutcome {
    _ = capacity;

    const manifests = @import("workspace/manifest.zig").Manifests.borrow(&.{"manifest"}, packages);
    const paths = memory.borrowTextColumn("path", packages);
    var temporary: std.heap.ArenaAllocator = .init(allocator);

    defer temporary.deinit();

    const scratch = temporary.allocator();

    const portable_root = if (comptime std.fs.path.sep == '/') root else path: {
        const native = try std.fs.path.resolve(scratch, &.{root});

        std.mem.replaceScalar(u8, native, std.fs.path.sep, '/');

        break :path native;
    };

    const result = assembly.executeValue(scratch, .{
        .manifests = &manifests.input(),
        .paths = @ptrCast(&paths),
        .root = portable_root,
        .count = packages.len,
        .limit = std.math.maxInt(usize),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (result.status == .Valid) {
        for (result.edges, edges) |src, *dst| {
            dst.* = .{
                .name = src.name,
                .target = @intCast(src.target),
                .development = src.development,
            };
        }
    }

    return .{
        .owner = result.owner,
        .edge = result.edge,
        .status = result.status,
    };
}
