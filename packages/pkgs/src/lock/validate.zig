const std = @import("std");
const Lock = @import("../lock.zig");

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

    const graph = try @import("../graph.zig").check(temporary, lock.packages, .lock);

    switch (graph.status) {
        .Valid => {},
        .CyclicPackageDependencies => return error.CyclicPackageDependencies,
        .PackageDependencyDepthExceeded => return error.PackageDependencyDepthExceeded,
        .UnreachableLockPackage => return error.UnreachableLockPackage,
    }
}
