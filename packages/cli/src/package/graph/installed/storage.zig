const std = @import("std");
const abi = @import("cli_abi");
const pkgs = @import("pkgs");
const graph = @import("../../graph.zig");
const files = @import("../../install/files.zig");
const model = @import("../../install/model.zig");
const host = @import("../host.zig");
const store = @import("package_store");
const MappingView = abi.layouts.@"zig:package_graph_host".Mapping;

pub fn openLock(handle: *anyopaque) host.Error!?bool {
    const self = host.State.get(handle);

    self.locked = (files.load(self.io, self.allocator, self.result.root, self.inputs) catch |err| return self.fail(err)) orelse return null;

    return model.matchesWorkspace(self.locked.lock, self.members);
}

pub fn openMapping(handle: *anyopaque) host.Error!?*const MappingView {
    const self = host.State.get(handle);

    self.mapping = (files.readMapping(self.io, self.allocator, self.result.root, self.locked, self.inputs) catch |err| return self.fail(err)) orelse return null;

    const packages = self.locked.lock.packages;
    const is_archive = self.allocator.alloc(bool, packages.len) catch |err| return self.fail(err);
    const sources = self.allocator.alloc([]const u8, packages.len) catch |err| return self.fail(err);

    for (packages, 0..) |package, index| {
        if (package.source == .archive) {
            is_archive[index] = true;
            sources[index] = package.source.archive.sha256;
        } else {
            is_archive[index] = false;
            sources[index] = package.source.workspace;
        }
    }

    self.mapping_view = .{
        .version = self.mapping.value.format_version,
        .digest = self.mapping.value.lock_sha256,
        .expected = &self.mapping.expected,
        .paths = self.mapping.value.paths,
        .is_archive = is_archive,
        .sources = sources,
        .root = self.result.root,
    };

    return &self.mapping_view;
}

pub fn prepareInstalled(handle: *anyopaque) host.Error!void {
    const self = host.State.get(handle);
    self.installed_packages = self.allocator.alloc(graph.Package, self.locked.lock.packages.len) catch |err| return self.fail(err);
}

pub fn canonical(handle: *anyopaque, path: []const u8) host.Error![]const u8 {
    const self = host.State.get(handle);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator) catch |err| self.fail(err);
}

pub fn verifyReceipt(handle: *anyopaque, parent: []const u8, digest: []const u8) host.Error!void {
    const self = host.State.get(handle);
    const io = self.io;
    const allocator = self.allocator;
    const receipt = std.fs.path.join(allocator, &.{ parent, store.constants.receipt_file }) catch |err| return self.fail(err);

    if (self.inputs) |observed| observed.add(io, receipt) catch |err| return self.fail(err);

    var directory = std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false }) catch |err| return self.fail(err);

    defer directory.close(io);
    store.receipt.verify(io, allocator, directory, digest) catch |err| return self.fail(err);
}

pub fn readInstalledArchive(handle: *anyopaque, index: u64, path: []const u8) host.Error!bool {
    const self = host.State.get(handle);

    self.archive = model.read(self.io, self.allocator, path, self.inputs, self.manifests) catch |err| return self.fail(err);

    return model.matches(self.archive, self.locked.lock.packages[@intCast(index)]);
}

pub fn recordInstalledArchive(handle: *anyopaque, index: u64, path: []const u8) void {
    const self = host.State.get(handle);

    self.installed_packages[@intCast(index)] = .{ .path = path, .manifest = self.archive };
}

pub fn recordMember(handle: *anyopaque, index: u64, ordinal: u64, path: []const u8) bool {
    const self = host.State.get(handle);
    const relative = self.locked.lock.packages[@intCast(index)].source.workspace;
    const row = pkgs.workspace.manifest.memberAt(self.members, @intCast(ordinal), relative) orelse return false;

    self.installed_packages[@intCast(index)] = .{ .path = path, .manifest = self.members[row].manifest };

    return true;
}
