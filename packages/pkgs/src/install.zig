const std = @import("std");
const memory = @import("memory");
const rules = @import("pkgs_source");
const Index = @import("index.zig");
const Lock = @import("lock.zig");
const Members = @import("workspace/selection.zig").Members;
const Input = std.meta.Child(rules.install_advance.Input);

pub const Resolver = struct {
    members: Members,
    index: Index,
    names: memory.TextColumn,
    versions: memory.ListColumn,
    pub fn init(members: anytype, index: Index) Resolver {
        return .{
            .members = Members.manifests(members),
            .index = index,
            .names = memory.borrowTextColumn("name", index.packages),
            .versions = memory.borrowListColumn([]const u8, "versions", "version", index.packages),
        };
    }
};

const Entries = struct {
    names: memory.TextColumn,
    requirements: memory.TextColumn,
    count: usize,
    fn borrow(items: anytype) Entries {
        return .{
            .names = memory.borrowTextColumn("name", items),
            .requirements = memory.borrowTextColumn("requirement", items),
            .count = items.len,
        };
    }

    fn input(self: *const Entries) std.meta.Child(@FieldType(Input, "production")) {
        return .{ .names = @ptrCast(&self.names), .requirements = @ptrCast(&self.requirements), .count = self.count };
    }
};

pub const Dependencies = struct {
    production: Entries,
    development: Entries,
    rows: std.ArrayList(Lock.Dependency) = .empty,
    cursor: u64,
    pub fn init(self: *Dependencies, manifest: anytype) void {
        self.production = Entries.borrow(manifest.dependencies);
        self.development = Entries.borrow(manifest.dev_dependencies);
        self.rows = .empty;
        self.cursor = 0;
    }

    pub const Pending = struct { name: []const u8, release: Index.Release };

    pub fn accept(self: *Dependencies, target: usize) void {
        self.rows.items[@intCast(self.cursor)].target = target;

        self.cursor += 1;
    }
    pub fn advance(self: *Dependencies, allocator: std.mem.Allocator, resolver: *const Resolver, owner: ?[]const u8, remaining: usize) !?Pending {
        const members = &resolver.members;
        const limit = std.math.maxInt(usize);

        const next = rules.install_advance.executeValue(allocator, &.{
            .members = &.{ .names = @ptrCast(&members.names), .versions = @ptrCast(&members.versions), .paths = @ptrCast(&members.paths), .count = members.count, .local = &.{} },
            .catalog = &.{ .names = @ptrCast(&resolver.names), .versions = @ptrCast(&resolver.versions), .count = resolver.index.packages.len, .limit = limit },
            .production = &self.production.input(),
            .development = &self.development.input(),
            .owner = owner,
            .cursor = self.cursor,
            .remaining = remaining,
            .limit = limit,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        try self.rows.ensureUnusedCapacity(allocator, next.rows.len);

        for (next.rows) |row| {
            self.rows.appendAssumeCapacity(.{
                .name = row.name,
                .requirement = row.requirement,
                .target = @intCast(row.target),
                .development = row.development,
            });
        }

        return switch (next.status) {
            .Done => done: {
                self.cursor = next.cursor;

                break :done null;
            },
            .Archive => pending: {
                self.cursor = next.cursor;

                break :pending .{
                    .name = next.pending_name.?,
                    .release = resolver.index.packages[@intCast(next.package)].versions[@intCast(next.release)],
                };
            },
            .TooManyLockDependencies => error.TooManyLockDependencies,
            .InvalidLockWorkspaceTarget => error.InvalidLockWorkspaceTarget,
            .InvalidLockWorkspacePath => error.InvalidLockWorkspacePath,
            .LockVersionMismatch => error.LockVersionMismatch,
            .InvalidRange => error.InvalidRange,
            .InvalidVersion => error.InvalidVersion,
            .Overflow => error.Overflow,
            .PackageVersionNotFound => error.PackageVersionNotFound,
        };
    }
};

pub const Archives = struct {
    const Rule = rules.install_archive;
    const State = std.meta.Child(@FieldType(Rule.zx_pending, "store_0"));

    const StoreHost = struct {
        store_0: *State,
        archive: *Archives,
        pub fn commit(self: *StoreHost, pending: anytype) std.mem.Allocator.Error!void {
            const next = pending.store_0 orelse return;
            const archive = self.archive;
            const retained = archive.buckets;
            const updated = next.buckets;

            if (retained.ptr != updated.ptr or retained.len != updated.len) {
                if (retained.len == updated.len) {
                    @memcpy(retained, updated);
                } else {
                    archive.buckets = try archive.allocator.dupe(u32, updated);
                    archive.allocator.free(retained);
                }
            }

            archive.indexed = @intCast(next.indexed);
        }
    };
    allocator: std.mem.Allocator,
    buckets: []u32 = &.{},
    indexed: usize = 0,
    const Selection = union(enum) { existing: usize, remote, local };

    pub fn deinit(self: *Archives) void {
        self.allocator.free(self.buckets);
    }
    pub fn plan(self: *Archives, packages: []const Lock.Package, first: usize, digest: []const u8, name: []const u8, release: Index.Release) !Selection {
        const archives = packages[first..];
        const names = memory.borrowTextColumn("name", archives);
        const versions = memory.borrowTextColumn("version", archives);
        var sample: Lock.Package = undefined;
        sample.source = .{ .archive = undefined };
        const digests = memory.borrowProjectedText(archives, &sample, &sample.source.archive.sha256);
        var arena = std.heap.ArenaAllocator.init(self.allocator);

        defer arena.deinit();

        var buffer: [2048]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
        const state: std.meta.Child(State) = .{ .buckets = self.buckets, .indexed = self.indexed };
        var state_ptr: State = &state;
        var host: StoreHost = .{ .store_0 = &state_ptr, .archive = self };

        const selected = Rule.executeIn(scratch.allocator(), &.{
            .names = @ptrCast(&names),
            .versions = @ptrCast(&versions),
            .digests = @ptrCast(&digests),
            .first = first,
            .count = archives.len,
            .maximum = Lock.maximum_packages,
            .digest = digest,
            .name = name,
            .version = release.version,
            .archive = release.archive,
        }, &host) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        return switch (selected.action) {
            .Existing => .{ .existing = @intCast(selected.row) },
            .Local => .local,
            .Remote => .remote,
            .InvalidLockPackageCount => error.InvalidLockPackageCount,
            .PackageArchiveIdentityMismatch => error.PackageArchiveIdentityMismatch,
        };
    }
};

pub fn verify(name: []const u8, version: []const u8, manifest: anytype) error{ PackageArchiveIdentityMismatch, ArchiveContainsWorkspace }!void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const status = rules.install_identity.executeIn(empty.allocator(), &.{
        .name = manifest.name,
        .version = manifest.version,
        .expected_name = name,
        .expected_version = version,
        .has_workspace = manifest.workspace != null,
    }) catch unreachable;

    return switch (status) {
        .Valid => {},
        .PackageArchiveIdentityMismatch => error.PackageArchiveIdentityMismatch,
        .ArchiveContainsWorkspace => error.ArchiveContainsWorkspace,
    };
}

pub const archiveTransport = rules.archive_transport.executeIn;
