const std = @import("std");
const rules = @import("pkgs_source");
const Lock = @import("lock.zig");

pub const Specifier = union(enum) {
    external,
    invalid,
    path: []const u8,
    named: struct { name: []const u8, range: ?[]const u8 },
};

pub fn parse(name: []const u8, text: []const u8) Specifier {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const spec = rules.specifier.executeValue(empty.allocator(), text) catch unreachable;

    return switch (spec.kind) {
        .External => .external,
        .Invalid => .invalid,
        .Path => .{ .path = text[@intCast(spec.body)..] },
        .Alias, .Name => .{ .named = .{
            .name = if (spec.kind == .Alias) text[@intCast(spec.body)..@intCast(spec.range - 1)] else name,
            .range = if (spec.constrained) text[@intCast(spec.range)..] else null,
        } },
    };
}

pub fn validPath(owner: []const u8, path: []const u8, kind: @FieldType(@typeInfo(rules.workspace_path.Input).pointer.child, "kind")) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rules.workspace_path.executeIn(empty.allocator(), &.{ .owner = owner, .path = path, .kind = kind }) catch unreachable;
}

pub fn checkOwner(spec: Specifier, owner: []const u8) !void {
    switch (spec) {
        .external, .invalid => return error.InvalidLockWorkspaceTarget,
        .path => |path| if (!validPath(owner, path, .Dependency)) return error.InvalidLockWorkspacePath,
        .named => {},
    }
}

pub fn matches(spec: Specifier, owner: []const u8, target: Lock.Package) !bool {
    switch (spec) {
        .external, .invalid => unreachable,
        .path => |path| {
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return rules.same_path.executeIn(empty.allocator(), &.{ .owner = owner, .path = path, .target = target.source.workspace }) catch unreachable;
        },
        .named => |named| {
            if (!std.mem.eql(u8, named.name, target.name)) return false;

            if (named.range) |range| {
                if (!try @import("version.zig").matches(range, try std.SemanticVersion.parse(target.version))) return error.LockVersionMismatch;
            }

            return true;
        },
    }
}

pub fn find(spec: Specifier, packages: []const Lock.Package, owner: usize) !usize {
    if (owner >= packages.len or packages[owner].source != .workspace) return error.InvalidLockWorkspaceTarget;

    const path = packages[owner].source.workspace;

    try checkOwner(spec, path);

    for (packages, 0..) |package, index| {
        if (package.source == .workspace and try matches(spec, path, package)) return index;
    }

    return error.InvalidLockWorkspaceTarget;
}
