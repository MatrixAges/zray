const std = @import("std");
const memory = @import("memory");
const rule = @import("pkgs_source").workspace_select;
const Lock = @import("../lock.zig");
const LockRows = @import("lock_rows.zig");
const workspace = @import("../workspace.zig");
const Input = std.meta.Child(rule.Input);
const Key = @FieldType(Input, "kind");

pub const Members = struct {
    count: usize,
    names: memory.TextColumn,
    paths: memory.TextColumn,
    versions: memory.TextColumn,
    pub fn manifests(items: anytype) Members {
        return .{
            .count = items.len,
            .paths = memory.borrowTextColumn("path", items),
            .names = memory.borrowNestedColumn([]const u8, &.{ "manifest", "name" }, items),
            .versions = memory.borrowNestedColumn([]const u8, &.{ "manifest", "version" }, items),
        };
    }
    fn locked(items: []const Lock.Package) Members {
        return .{
            .count = items.len,
            .names = memory.borrowTextColumn("name", items),
            .paths = LockRows.paths(items),
            .versions = memory.borrowTextColumn("version", items),
        };
    }
    pub fn select(self: *const Members, spec: workspace.Specifier, owner: []const u8) !usize {
        if (spec == .invalid or spec == .external) return error.InvalidLockWorkspaceTarget;

        return (try self.lookup(spec, owner, &.{}, true)) orelse error.InvalidLockWorkspaceTarget;
    }
    pub fn absolute(self: *const Members, root: []const u8, path: []const u8) ?usize {
        return self.search(.HostPath, path, root, null, &.{}) catch unreachable;
    }
    fn lookup(self: *const Members, spec: workspace.Specifier, owner: []const u8, local: []const u8, check_owner: bool) !?usize {
        return switch (spec) {
            .path => |path| self.search(if (check_owner) .CheckedRelativePath else .RelativePath, path, owner, null, local),
            .named => |named| self.search(.Name, named.name, owner, named.range, local),
            .invalid, .external => unreachable,
        };
    }
    fn search(self: *const Members, kind: Key, value: []const u8, owner: []const u8, range: ?[]const u8, local: []const u8) !?usize {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const selected = rule.executeValue(empty.allocator(), .{
            .count = self.count,
            .names = @ptrCast(&self.names),
            .paths = @ptrCast(&self.paths),
            .versions = @ptrCast(&self.versions),
            .local = local,
            .kind = kind,
            .value = value,
            .owner = owner,
            .range = range,
            .limit = std.math.maxInt(usize),
        }) catch unreachable;

        return switch (selected.status) {
            .Found => @intCast(selected.row),
            .Missing => null,
            .InvalidRange => error.InvalidRange,
            .InvalidVersion => error.InvalidVersion,
            .Overflow => error.Overflow,
            .LockVersionMismatch => error.LockVersionMismatch,
            .InvalidLockWorkspacePath => error.InvalidLockWorkspacePath,
        };
    }
};

pub fn find(spec: workspace.Specifier, packages: []const Lock.Package, owner: usize) !usize {
    if (owner >= packages.len or packages[owner].source != .workspace) return error.InvalidLockWorkspaceTarget;

    const path = packages[owner].source.workspace;

    if (spec == .invalid or spec == .external) return error.InvalidLockWorkspaceTarget;

    var window: LockRows = .{};
    var first: usize = 0;
    var check_owner = true;

    while (first < packages.len) {
        const rows = window.take(packages[first..]);

        if (window.count != 0) {
            const view = Members.locked(rows);

            if (try view.lookup(spec, path, window.local, check_owner)) |row| return first + row;

            check_owner = false;
        }

        first += rows.len;
    }

    return error.InvalidLockWorkspaceTarget;
}

pub fn matches(spec: workspace.Specifier, owner: []const u8, target: Lock.Package) !bool {
    if (spec == .path) _ = target.source.workspace;

    const member = Members.locked(&.{target});

    return (try member.lookup(spec, owner, &.{}, false)) != null;
}
