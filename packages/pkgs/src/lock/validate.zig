const std = @import("std");
const Lock = @import("../lock.zig");
const State = enum { fresh, visiting, done };

pub fn validate(lock: Lock, allocator: std.mem.Allocator) !void {
    if (lock.format_version != 1) return error.UnsupportedLockVersion;
    if (lock.packages.len == 0 or lock.packages.len > Lock.maximum_packages) return error.InvalidLockPackageCount;
    if (lock.packages[0].source != .workspace or !std.mem.eql(u8, lock.packages[0].source.workspace, ".")) return error.MissingLockWorkspaceRoot;

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    var identities: std.StringHashMapUnmanaged(void) = .empty;
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var digests: std.StringHashMapUnmanaged(void) = .empty;
    var edge_count: usize = 0;

    for (lock.packages) |package| {
        if (!@import("../metadata.zig").validName(package.name)) return error.InvalidPackageName;

        _ = try std.SemanticVersion.parse(package.version);

        switch (package.source) {
            .workspace => |path| {
                if (!@import("../workspace.zig").validPath("", path, .Stored)) return error.InvalidLockWorkspacePath;
                if ((try paths.getOrPut(temporary, path)).found_existing) return error.DuplicateLockWorkspacePath;
                if ((try names.getOrPut(temporary, package.name)).found_existing) return error.DuplicateLockWorkspaceName;
            },
            .archive => |source| {
                try @import("../metadata.zig").validateArchive(source.archive, source.sha256, true);
                if ((try digests.getOrPut(temporary, source.sha256)).found_existing) return error.DuplicateLockArchive;

                const identity = try std.fmt.allocPrint(temporary, "{s}@{s}", .{ package.name, package.version });

                if ((try identities.getOrPut(temporary, identity)).found_existing) return error.DuplicateLockPackage;
            },
        }

        if (package.dependencies.len > Lock.maximum_dependencies - edge_count) return error.TooManyLockDependencies;

        edge_count += package.dependencies.len;
    }

    for (lock.packages) |package| try @import("edges.zig").validate(lock, temporary, package);

    const states = try temporary.alloc(State, lock.packages.len);
    const heights = try temporary.alloc(usize, lock.packages.len);

    @memset(states, .fresh);

    for (lock.packages, 0..) |package, index| {
        if (package.source == .workspace) try visit(lock, states, heights, index, 0);
    }

    for (states) |state| if (state != .done) return error.UnreachableLockPackage;
}

fn visit(lock: Lock, states: []State, heights: []usize, index: usize, depth: usize) error{ CyclicPackageDependencies, PackageDependencyDepthExceeded }!void {
    if (states[index] == .visiting) return error.CyclicPackageDependencies;
    if (depth >= 256) return error.PackageDependencyDepthExceeded;

    if (states[index] == .done) {
        if (depth + heights[index] >= 256) return error.PackageDependencyDepthExceeded;

        return;
    }

    states[index] = .visiting;
    heights[index] = 0;

    for (lock.packages[index].dependencies) |edge| {
        try visit(lock, states, heights, edge.target, depth + 1);

        heights[index] = @max(heights[index], heights[edge.target] + 1);
    }

    states[index] = .done;
}
