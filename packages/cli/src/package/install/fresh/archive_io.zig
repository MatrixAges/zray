const std = @import("std");
const host = @import("../host.zig");
const model = @import("../model.zig");
const pkgs = @import("pkgs");

pub fn findArchive(handle: *const anyopaque, first: u64) host.Error!?u64 {
    const self = host.State.get(handle);
    const fresh = &self.fresh;
    const release = fresh.pending.release;
    const key = std.ascii.lowerString(&fresh.spelling, release.sha256);
    const plan = fresh.archives.?.plan(fresh.packages.items, @intCast(first), key, fresh.pending.name, release) catch |err| return self.fail(err);

    return switch (plan) {
        .existing => |row| row,
        .remote, .local => result: {
            fresh.archive_is_local = plan == .local;

            break :result null;
        },
    };
}

pub fn localArchive(handle: *const anyopaque) bool {
    return host.State.get(handle).fresh.archive_is_local;
}

pub fn indexedArchive(handle: *const anyopaque) []const u8 {
    return host.State.get(handle).fresh.pending.release.archive;
}

pub fn relativeArchive(handle: *const anyopaque) host.Error![]const u8 {
    const self = host.State.get(handle);
    const allocator = self.allocator;
    const absolute = std.fs.path.resolve(allocator, &.{ self.fresh.index_base, self.fresh.pending.release.archive }) catch |err| return self.fail(err);
    const relative = std.fs.path.relative(allocator, self.root, null, self.root, absolute) catch |err| return self.fail(err);

    std.mem.replaceScalar(u8, relative, '\\', '/');

    return relative;
}

pub fn fetchArchive(handle: *const anyopaque, source: []const u8) host.Error![]const u8 {
    const self = host.State.get(handle);
    const fresh = &self.fresh;
    const release = fresh.pending.release;
    const key = fresh.spelling[0..release.sha256.len];
    const digest = if (std.mem.eql(u8, key, release.sha256)) release.sha256 else self.allocator.dupe(u8, key) catch |err| return self.fail(err);

    fresh.pending.release.sha256 = digest;

    return self.fetch(.{ .version = release.version, .archive = source, .sha256 = digest }, self.root) catch |err| self.fail(err);
}

pub fn readArchive(handle: *const anyopaque, path: []const u8) host.Error!void {
    const self = host.State.get(handle);
    const allocator = self.allocator;
    self.fresh.archive_manifest = model.read(self.io, allocator, path, null, allocator) catch |err| return self.fail(err);
}

pub fn verifyArchive(handle: *const anyopaque) host.Error!void {
    const self = host.State.get(handle);
    const fresh = &self.fresh;

    pkgs.install.verify(fresh.pending.name, fresh.pending.release.version, &fresh.archive_manifest) catch |err| return self.fail(err);
}

pub fn recordArchive(handle: *const anyopaque, source: []const u8, path: []const u8) host.Error!u64 {
    const self = host.State.get(handle);
    const fresh = &self.fresh;
    const allocator = self.allocator;
    const data = &fresh.archive_manifest;
    const row = fresh.packages.items.len;

    fresh.packages.append(allocator, .{
        .name = data.name,
        .version = data.version,
        .source = .{ .archive = .{ .archive = source, .sha256 = fresh.pending.release.sha256 } },
        .dependencies = &.{},
    }) catch |err| return self.fail(err);

    fresh.paths.append(allocator, self.physicalPath(path) catch |err| return self.fail(err)) catch |err| return self.fail(err);
    fresh.archive_declarations.append(allocator, .{ .dependencies = data.dependencies, .dev_dependencies = data.dev_dependencies }) catch |err| return self.fail(err);

    return row;
}
