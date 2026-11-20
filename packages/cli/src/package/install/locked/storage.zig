const std = @import("std");
const host = @import("../host.zig");
const model = @import("../model.zig");

pub fn beginReplay(handle: *const anyopaque, count: u64) host.Error!void {
    const self = host.State.get(handle);
    const previous = self.previous.?;

    self.prepared = .{
        .lock = previous.lock,
        .source = previous.source,
        .paths = self.allocator.alloc([]const u8, @intCast(count)) catch |err| return self.fail(err),
    };
}

pub fn lockedArchive(handle: *const anyopaque, row: u64) bool {
    return host.State.get(handle).prepared.lock.packages[@intCast(row)].source == .archive;
}

pub fn workspacePath(handle: *const anyopaque, row: u64) host.Error![]const u8 {
    const self = host.State.get(handle);
    const relative = self.prepared.lock.packages[@intCast(row)].source.workspace;

    return std.fs.path.resolve(self.allocator, &.{ self.root, relative }) catch |err| self.fail(err);
}

pub fn fetchLocked(handle: *const anyopaque, row: u64) host.Error![]const u8 {
    const self = host.State.get(handle);
    const package = &self.prepared.lock.packages[@intCast(row)];
    const source = package.source.archive;

    return self.fetch(.{ .version = package.version, .archive = source.archive, .sha256 = source.sha256 }, self.root) catch |err| self.fail(err);
}

pub fn recordLockedPath(handle: *const anyopaque, row: u64, location: []const u8) host.Error![]const u8 {
    const self = host.State.get(handle);
    const path = self.physicalPath(location) catch |err| return self.fail(err);

    @constCast(self.prepared.paths)[@intCast(row)] = path;

    return path;
}

pub fn verifyLockedManifest(handle: *const anyopaque, row: u64, path: []const u8) host.Error!void {
    const self = host.State.get(handle);
    const memory = self.scratch.allocator();
    const data = model.read(self.io, memory, path, null, memory) catch |err| return self.fail(err);

    if (!model.matches(data, self.prepared.lock.packages[@intCast(row)])) return self.fail(error.InstalledManifestDoesNotMatchLock);

    _ = self.scratch.reset(.retain_capacity);
}
