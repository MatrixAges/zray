const std = @import("std");
const host = @import("../host.zig");
const model = @import("../model.zig");
const fresh = @import("storage.zig");
const pkgs = @import("pkgs");
const abi = @import("cli_abi").layouts.@"zig:installation_host";
const ArchiveAdmission = @import("cli_abi").native.@"zig:installation_host".ArchiveAdmission;

fn releaseOf(value: *const abi.Release, source: []const u8) pkgs.Index.Release {
    return .{ .version = value.version, .archive = source, .sha256 = value.sha256 };
}

pub fn findArchive(handle: *const anyopaque, first: u64, release: *const abi.Release) host.Error!*const abi.ArchiveLookup {
    const build = fresh.State.get(handle);
    const session = build.session;
    const plan = build.archives.plan(build.packages.items, @intCast(first), release.sha256, release.name, releaseOf(release, release.archive)) catch |err| return session.fail(err);
    const view = session.allocator.create(abi.ArchiveLookup) catch |err| return session.fail(err);

    view.* = switch (plan) {
        .existing => |row| .{ .existing = row, .local = false },
        .remote, .local => .{ .existing = null, .local = plan == .local },
    };

    return view;
}

pub fn fetchArchive(handle: *const anyopaque, source: []const u8, release: *const abi.Release) host.Error![]const u8 {
    const session = host.Context.get(handle);

    return session.fetch(releaseOf(release, source), session.root) catch |err| session.fail(err);
}

pub fn readArchive(handle: *const anyopaque, path: []const u8) host.Error!*const abi.ArchiveIdentity {
    const build = fresh.State.get(handle);
    const session = build.session;
    const allocator = session.allocator;
    const manifest = model.read(session.io, allocator, path, null, allocator) catch |err| return session.fail(err);
    build.archive_manifest = manifest;

    build.archive_identity = .{
        .name = manifest.name,
        .version = manifest.version,
        .has_workspace = manifest.workspace != null,
    };

    return &build.archive_identity;
}

pub fn recordArchive(handle: *const anyopaque, source: []const u8, digest: []const u8, admission: ArchiveAdmission) host.Error!u64 {
    const build = fresh.State.get(handle);
    const session = build.session;

    switch (admission) {
        .Valid => {},
        .IdentityMismatch => return session.fail(error.PackageArchiveIdentityMismatch),
        .ContainsWorkspace => return session.fail(error.ArchiveContainsWorkspace),
    }

    const allocator = session.allocator;
    const data = &build.archive_manifest;
    const row = build.packages.items.len;

    build.packages.append(allocator, .{
        .name = data.name,
        .version = data.version,
        .source = .{ .archive = .{ .archive = source, .sha256 = digest } },
        .dependencies = &.{},
    }) catch |err| return session.fail(err);

    build.archive_declarations.append(allocator, .{ .dependencies = data.dependencies, .dev_dependencies = data.dev_dependencies }) catch |err| return session.fail(err);

    return row;
}
