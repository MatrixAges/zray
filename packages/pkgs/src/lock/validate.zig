const std = @import("std");
const memory = @import("memory");
const rules = @import("pkgs_source");
const Lock = @import("../lock.zig");
const graph = @import("../graph.zig");

pub fn validate(lock: Lock, allocator: std.mem.Allocator) !void {
    const packages = lock.packages;
    const root = if (packages.len != 0 and packages[0].source == .workspace) packages[0].source.workspace else null;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    try checkStatus(rules.lock_header.executeIn(empty.allocator(), &.{
        .format = lock.format_version,
        .count = packages.len,
        .maximum = Lock.maximum_packages,
        .root = root,
    }) catch unreachable);

    const storage = try allocator.alloc(u8, 2 * packages.len);

    defer allocator.free(storage);

    var marks = storage[0..packages.len];
    var heights = storage[packages.len..];

    graph.prepare(storage, packages, .lock);

    var sample: Lock.Package = undefined;
    sample.source = .{ .workspace = undefined };
    const paths = memory.borrowProjectedText(packages, &sample, &sample.source.workspace);
    sample.source = .{ .archive = undefined };

    const archives = memory.borrowProjectedText(packages, &sample, &sample.source.archive.archive);
    const digests = memory.borrowProjectedText(packages, &sample, &sample.source.archive.sha256);
    const names = memory.borrowTextColumn("name", packages);
    const versions = memory.borrowTextColumn("version", packages);
    const targets = memory.borrowListColumn(usize, "dependencies", "target", packages);
    const edge_names = memory.borrowListColumn([]const u8, "dependencies", "name", packages);
    const requirements = memory.borrowListColumn([]const u8, "dependencies", "requirement", packages);
    const development = memory.borrowListColumn(bool, "dependencies", "development", packages);
    var frames: graph.Frames = .{};
    const traversal = frames.input(&targets, &marks, &heights, true);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const result = rules.lock_validate.executeIn(scratch.allocator(), &.{
        .packages = &.{
            .names = @ptrCast(&names),
            .versions = @ptrCast(&versions),
            .paths = @ptrCast(&paths),
            .archives = @ptrCast(&archives),
            .digests = @ptrCast(&digests),
            .flags = @ptrCast(&marks),
            .count = packages.len,
            .limit = std.math.maxInt(usize),
        },
        .edges = &.{
            .targets = @ptrCast(&targets),
            .edge_names = @ptrCast(&edge_names),
            .requirements = @ptrCast(&requirements),
            .development = @ptrCast(&development),
        },
        .graph = &traversal,
        .maximum_edges = Lock.maximum_dependencies,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    try checkStatus(result);
}

fn checkStatus(status: rules.lock_header.Output) !void {
    switch (status) {
        .Valid => {},
        .UnsupportedLockVersion => return error.UnsupportedLockVersion,
        .InvalidLockPackageCount => return error.InvalidLockPackageCount,
        .MissingLockWorkspaceRoot => return error.MissingLockWorkspaceRoot,
        .InvalidPackageName => return error.InvalidPackageName,
        .InvalidVersion => return error.InvalidVersion,
        .Overflow => return error.Overflow,
        .InvalidLockWorkspacePath => return error.InvalidLockWorkspacePath,
        .DuplicateLockWorkspacePath => return error.DuplicateLockWorkspacePath,
        .DuplicateLockWorkspaceName => return error.DuplicateLockWorkspaceName,
        .InvalidArchiveSource => return error.InvalidArchiveSource,
        .InvalidArchiveDigest => return error.InvalidArchiveDigest,
        .DuplicateLockArchive => return error.DuplicateLockArchive,
        .DuplicateLockPackage => return error.DuplicateLockPackage,
        .TooManyLockDependencies => return error.TooManyLockDependencies,
        .DuplicateLockDependency => return error.DuplicateLockDependency,
        .InvalidLockTarget => return error.InvalidLockTarget,
        .ArchiveHasDevelopmentDependency => return error.ArchiveHasDevelopmentDependency,
        .InvalidLockWorkspaceTarget => return error.InvalidLockWorkspaceTarget,
        .InvalidLockArchiveTarget => return error.InvalidLockArchiveTarget,
        .InvalidRange => return error.InvalidRange,
        .LockVersionMismatch => return error.LockVersionMismatch,
        .CyclicPackageDependencies => return error.CyclicPackageDependencies,
        .PackageDependencyDepthExceeded => return error.PackageDependencyDepthExceeded,
        .UnreachableLockPackage => return error.UnreachableLockPackage,
    }
}
