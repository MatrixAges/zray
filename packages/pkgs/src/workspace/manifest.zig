const std = @import("std");
const memory = @import("memory");
const rules = @import("pkgs_source");
const Lock = @import("../lock.zig");
const LockRows = @import("lock_rows.zig");
const Pair = std.meta.Child(rules.manifest_matches.Input);
const Location = @typeInfo(@TypeOf(rules.first_external.executeValue(undefined, undefined))).error_union.payload;

pub fn firstExternal(members: anytype) ?Location {
    const production = memory.borrowListPath([]const u8, &.{ "manifest", "dependencies" }, &.{"requirement"}, members);
    const development = memory.borrowListPath([]const u8, &.{ "manifest", "dev_dependencies" }, &.{"requirement"}, members);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const found = rules.first_external.executeValue(empty.allocator(), &.{
        .count = members.len,
        .production = @ptrCast(&production),
        .development = @ptrCast(&development),
    }) catch unreachable;

    return if (found.found) found else null;
}

const Manifests = struct {
    names: memory.TextColumn,
    versions: memory.TextColumn,
    production_names: memory.ListColumn,
    production_requirements: memory.ListColumn,
    development_names: memory.ListColumn,
    development_requirements: memory.ListColumn,
    fn borrow(comptime prefix: []const []const u8, rows: anytype) Manifests {
        const production = prefix ++ &[_][]const u8{"dependencies"};
        const development = prefix ++ &[_][]const u8{"dev_dependencies"};

        return .{
            .names = memory.borrowNestedColumn([]const u8, prefix ++ &[_][]const u8{"name"}, rows),
            .versions = memory.borrowNestedColumn([]const u8, prefix ++ &[_][]const u8{"version"}, rows),
            .production_names = memory.borrowListPath([]const u8, production, &.{"name"}, rows),
            .production_requirements = memory.borrowListPath([]const u8, production, &.{"requirement"}, rows),
            .development_names = memory.borrowListPath([]const u8, development, &.{"name"}, rows),
            .development_requirements = memory.borrowListPath([]const u8, development, &.{"requirement"}, rows),
        };
    }

    fn input(self: *const Manifests) std.meta.Child(@FieldType(Pair, "manifests")) {
        return .{
            .names = @ptrCast(&self.names),
            .versions = @ptrCast(&self.versions),
            .production_names = @ptrCast(&self.production_names),
            .production_requirements = @ptrCast(&self.production_requirements),
            .development_names = @ptrCast(&self.development_names),
            .development_requirements = @ptrCast(&self.development_requirements),
        };
    }
};

const Locked = struct {
    names: memory.TextColumn,
    versions: memory.TextColumn,
    edge_names: memory.ListColumn,
    requirements: memory.ListColumn,
    kinds: memory.ListColumn,
    fn borrow(rows: []const Lock.Package) Locked {
        return .{
            .names = memory.borrowTextColumn("name", rows),
            .versions = memory.borrowTextColumn("version", rows),
            .edge_names = memory.borrowListColumn([]const u8, "dependencies", "name", rows),
            .requirements = memory.borrowListColumn([]const u8, "dependencies", "requirement", rows),
            .kinds = memory.borrowListColumn(bool, "dependencies", "development", rows),
        };
    }

    fn input(self: *const Locked) std.meta.Child(@FieldType(Pair, "locked")) {
        return .{
            .names = @ptrCast(&self.names),
            .versions = @ptrCast(&self.versions),
            .edge_names = @ptrCast(&self.edge_names),
            .requirements = @ptrCast(&self.requirements),
            .kinds = @ptrCast(&self.kinds),
        };
    }
};

pub fn matches(data: anytype, package: Lock.Package) bool {
    const rows: []const @TypeOf(data) = @as(*const [1]@TypeOf(data), @ptrCast(&data));
    const manifests = Manifests.borrow(&.{}, rows);
    const locked = Locked.borrow(@as(*const [1]Lock.Package, @ptrCast(&package)));
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rules.manifest_matches.executeIn(empty.allocator(), &.{
        .manifests = &manifests.input(),
        .locked = &locked.input(),
        .member = 0,
        .package = 0,
        .archive = package.source == .archive,
        .has_workspace = data.workspace != null,
    }) catch unreachable;
}

pub fn memberAt(members: anytype, ordinal: usize, path: []const u8) ?usize {
    const paths = memory.borrowTextColumn("path", members);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const selected = rules.workspace_member.executeIn(empty.allocator(), &.{
        .paths = @ptrCast(&paths),
        .count = members.len,
        .ordinal = ordinal,
        .path = path,
    }) catch unreachable;

    return if (selected) |row| @intCast(row) else null;
}

pub fn matchesWorkspace(lock: Lock, members: anytype) bool {
    const manifests = Manifests.borrow(&.{"manifest"}, members);
    const paths = memory.borrowTextColumn("path", members);
    var ordinal: u64 = 0;
    var first: usize = 0;
    var window: LockRows = .{};
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (first < lock.packages.len) {
        const rows = window.take(lock.packages[first..]);

        first += rows.len;

        if (window.count == 0) continue;

        const locked = Locked.borrow(rows);
        const locked_paths = LockRows.paths(rows);

        const next = rules.workspace_compare.executeIn(empty.allocator(), &.{
            .manifests = &manifests.input(),
            .locked = &locked.input(),
            .paths = @ptrCast(&paths),
            .count = members.len,
            .ordinal = ordinal,
            .local = window.local,
            .length = rows.len,
            .locked_paths = @ptrCast(&locked_paths),
        }) catch unreachable;

        ordinal = next orelse return false;
    }

    return ordinal == members.len;
}
