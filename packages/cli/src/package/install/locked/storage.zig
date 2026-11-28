const std = @import("std");
const host = @import("../host.zig");
const model = @import("../model.zig");

pub fn beginReplay(handle: *anyopaque, count: u64) host.Error![]const ?[]const u8 {
    const self = host.State.get(handle);
    const previous = self.previous.?;
    const workspace = self.allocator.alloc(?[]const u8, @intCast(count)) catch |err| return self.fail(err);

    for (previous.lock.packages, 0..) |package, index| {
        workspace[index] = if (package.source == .workspace) package.source.workspace else null;
    }

    self.prepared = .{
        .lock = previous.lock,
        .source = previous.source,
        .paths = self.allocator.alloc([]const u8, @intCast(count)) catch |err| return self.fail(err),
    };

    return workspace;
}

pub fn fetchLocked(handle: *anyopaque, row: u64) host.Error![]const u8 {
    const self = host.State.get(handle);
    const package = &self.prepared.lock.packages[@intCast(row)];
    const source = package.source.archive;

    return self.fetch(.{ .version = package.version, .archive = source.archive, .sha256 = source.sha256 }, self.root) catch |err| self.fail(err);
}

pub fn recordLockedPath(handle: *anyopaque, row: u64, location: []const u8) host.Error![]const u8 {
    const self = host.State.get(handle);
    const path = self.physicalPath(location) catch |err| return self.fail(err);

    self.prepared.paths[@intCast(row)] = path;

    return path;
}

pub fn verifyLockedManifest(handle: *anyopaque, row: u64, path: []const u8) host.Error!void {
    const self = host.State.get(handle);
    const memory = self.scratch.allocator();
    const data = model.read(self.io, memory, path, null, memory) catch |err| return self.fail(err);

    if (!model.matches(data, self.prepared.lock.packages[@intCast(row)])) return self.fail(error.InstalledManifestDoesNotMatchLock);

    _ = self.scratch.reset(.retain_capacity);
}
