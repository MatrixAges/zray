const std = @import("std");
const Lock = @import("../lock.zig");
const workspace = @import("../workspace.zig");
const version = @import("../version.zig");

pub fn validate(lock: Lock, allocator: std.mem.Allocator, owner: Lock.Package) !void {
    var names: std.StringHashMapUnmanaged(void) = .empty;

    defer names.deinit(allocator);

    for (owner.dependencies) |edge| {
        if (!@import("../metadata.zig").validName(edge.name)) return error.InvalidPackageName;
        if ((try names.getOrPut(allocator, edge.name)).found_existing) return error.DuplicateLockDependency;
        if (edge.target >= lock.packages.len) return error.InvalidLockTarget;
        if (owner.source == .archive and edge.development) return error.ArchiveHasDevelopmentDependency;

        const target = lock.packages[edge.target];
        const spec = workspace.parse(edge.name, edge.requirement);

        if (spec != .external) {
            if (owner.source != .workspace or target.source != .workspace) return error.InvalidLockWorkspaceTarget;
            try workspace.checkOwner(spec, owner.source.workspace);
            if (!try workspace.matches(spec, owner.source.workspace, target)) return error.InvalidLockWorkspaceTarget;
        } else {
            if (target.source != .archive or !std.mem.eql(u8, edge.name, target.name)) return error.InvalidLockArchiveTarget;
            if (!try version.matches(edge.requirement, try std.SemanticVersion.parse(target.version))) return error.LockVersionMismatch;
        }
    }
}
