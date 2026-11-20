const std = @import("std");
const pkgs = @import("pkgs");
const graph = @import("../../graph.zig");
const files = @import("../../install/files.zig");
const model = @import("../../install/model.zig");
const host = @import("../host.zig");
const store = @import("package_store");

pub fn openLock(handle: *const anyopaque) host.Error!bool {
    const self = host.State.get(handle);

    self.locked = (files.load(self.io, self.allocator, self.result.root, self.inputs) catch |err| return self.fail(err)) orelse return false;

    return true;
}

pub fn lockMatches(handle: *const anyopaque) bool {
    const self = host.State.get(handle);

    return model.matchesWorkspace(self.locked.lock, self.members);
}

pub fn openMapping(handle: *const anyopaque) host.Error!bool {
    const self = host.State.get(handle);

    self.mapping = (files.readMapping(self.io, self.allocator, self.result.root, self.locked, self.inputs) catch |err| return self.fail(err)) orelse return false;

    return true;
}

pub fn mappingVersion(handle: *const anyopaque) u32 {
    return host.State.get(handle).mapping.value.format_version;
}

pub fn mappingDigest(handle: *const anyopaque) []const u8 {
    return host.State.get(handle).mapping.value.lock_sha256;
}

pub fn expectedDigest(handle: *const anyopaque) []const u8 {
    return &host.State.get(handle).mapping.expected;
}

pub fn mappedPaths(handle: *const anyopaque) []const []const u8 {
    return host.State.get(handle).mapping.value.paths;
}

pub fn lockedCount(handle: *const anyopaque) u64 {
    return host.State.get(handle).locked.lock.packages.len;
}

pub fn prepareInstalled(handle: *const anyopaque) host.Error!void {
    const self = host.State.get(handle);
    self.installed_packages = self.allocator.alloc(graph.Package, self.locked.lock.packages.len) catch |err| return self.fail(err);
}

pub fn isArchive(handle: *const anyopaque, index: u64) bool {
    return host.State.get(handle).locked.lock.packages[@intCast(index)].source == .archive;
}

pub fn mappedPath(handle: *const anyopaque, index: u64) []const u8 {
    return host.State.get(handle).mapping.value.paths[@intCast(index)];
}

pub fn archiveDigest(handle: *const anyopaque, index: u64) []const u8 {
    return host.State.get(handle).locked.lock.packages[@intCast(index)].source.archive.sha256;
}

pub fn canonical(handle: *const anyopaque, path: []const u8) host.Error![]const u8 {
    const self = host.State.get(handle);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator) catch |err| self.fail(err);
}

pub fn verifyReceipt(handle: *const anyopaque, parent: []const u8, digest: []const u8) host.Error!void {
    const self = host.State.get(handle);
    const io = self.io;
    const allocator = self.allocator;
    const receipt = std.fs.path.join(allocator, &.{ parent, store.constants.receipt_file }) catch |err| return self.fail(err);

    if (self.inputs) |observed| observed.add(io, receipt) catch |err| return self.fail(err);

    var directory = std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false }) catch |err| return self.fail(err);

    defer directory.close(io);
    store.receipt.verify(io, allocator, directory, digest) catch |err| return self.fail(err);
}

pub fn readArchive(handle: *const anyopaque, path: []const u8) host.Error!void {
    const self = host.State.get(handle);

    self.archive = model.read(self.io, self.allocator, path, self.inputs, self.manifests) catch |err| return self.fail(err);
}

pub fn archiveMatches(handle: *const anyopaque, index: u64) bool {
    const self = host.State.get(handle);

    return model.matches(self.archive, self.locked.lock.packages[@intCast(index)]);
}

pub fn recordArchive(handle: *const anyopaque, index: u64, path: []const u8) void {
    const self = host.State.get(handle);

    self.installed_packages[@intCast(index)] = .{ .path = path, .manifest = self.archive };
}

pub fn workspacePath(handle: *const anyopaque, index: u64) host.Error![]const u8 {
    const self = host.State.get(handle);
    const relative = self.locked.lock.packages[@intCast(index)].source.workspace;
    const path = std.fs.path.resolve(self.allocator, &.{ self.result.root, relative }) catch |err| return self.fail(err);

    return canonical(handle, path);
}

pub fn recordMember(handle: *const anyopaque, index: u64, ordinal: u64, path: []const u8) bool {
    const self = host.State.get(handle);
    const relative = self.locked.lock.packages[@intCast(index)].source.workspace;
    const row = pkgs.workspace.manifest.memberAt(self.members, @intCast(ordinal), relative) orelse return false;

    self.installed_packages[@intCast(index)] = .{ .path = path, .manifest = self.members[row].manifest };

    return true;
}
