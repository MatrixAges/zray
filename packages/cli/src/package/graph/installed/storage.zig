const std = @import("std");
const abi = @import("cli_abi").layouts.@"zig:package_graph_host";
const pkgs = @import("pkgs");
const files = @import("../../install/files.zig");
const model = @import("../../install/model.zig");
const Manifest = @import("../../manifest/model.zig").Manifest;
const host = @import("../host.zig");
const store = @import("package_store");

pub fn openLock(allocator: std.mem.Allocator, handle: *const anyopaque, root: []const u8) host.Error!?*const abi.LoadedLock {
    const self = host.Context.get(handle);
    const loaded = (files.load(self.io, allocator, root, self.inputs) catch |err| return self.fail(err)) orelse return null;
    const lock = allocator.create(files.Loaded) catch |err| return self.fail(err);
    const view = allocator.create(abi.LoadedLock) catch |err| return self.fail(err);

    lock.* = loaded;

    view.* = .{ .lock = @ptrCast(lock), .matches = model.matchesWorkspace(lock.lock, self.members) };

    return view;
}

pub fn openMapping(allocator: std.mem.Allocator, handle: *const anyopaque, root: []const u8, lock_handle: *const anyopaque) host.Error!?*const abi.Mapping {
    const self = host.Context.get(handle);
    const lock: *const files.Loaded = @ptrCast(@alignCast(lock_handle));
    const loaded = (files.readMapping(self.io, allocator, root, lock.*, self.inputs) catch |err| return self.fail(err)) orelse return null;
    const packages = lock.lock.packages;
    const is_archive = allocator.alloc(bool, packages.len) catch |err| return self.fail(err);
    const sources = allocator.alloc([]const u8, packages.len) catch |err| return self.fail(err);

    for (packages, is_archive, sources) |package, *archive, *source| {
        archive.* = package.source == .archive;
        source.* = if (archive.*) package.source.archive.sha256 else package.source.workspace;
    }

    const expected = allocator.dupe(u8, &loaded.expected) catch |err| return self.fail(err);
    const view = allocator.create(abi.Mapping) catch |err| return self.fail(err);

    view.* = .{
        .version = loaded.value.format_version,
        .digest = loaded.value.lock_sha256,
        .expected = expected,
        .paths = loaded.value.paths,
        .is_archive = is_archive,
        .sources = sources,
        .root = root,
    };

    return view;
}

pub fn canonical(allocator: std.mem.Allocator, handle: *const anyopaque, path: []const u8) host.Error![]const u8 {
    const self = host.Context.get(handle);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, allocator) catch |err| self.fail(err);
}

pub fn verifyReceipt(allocator: std.mem.Allocator, handle: *const anyopaque, parent: []const u8, digest: []const u8) host.Error!void {
    const self = host.Context.get(handle);
    const io = self.io;
    const receipt = std.fs.path.join(allocator, &.{ parent, store.constants.receipt_file }) catch |err| return self.fail(err);

    if (self.inputs) |observed| observed.add(io, receipt) catch |err| return self.fail(err);

    var directory = std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false }) catch |err| return self.fail(err);

    defer directory.close(io);
    store.receipt.verify(io, allocator, directory, digest) catch |err| return self.fail(err);
}

pub fn readInstalledArchive(allocator: std.mem.Allocator, handle: *const anyopaque, lock_handle: *const anyopaque, index: u64, path: []const u8) host.Error!?*const abi.PackageManifest {
    const self = host.Context.get(handle);
    const lock: *const files.Loaded = @ptrCast(@alignCast(lock_handle));
    const data = model.read(self.io, allocator, path, self.inputs, self.manifests) catch |err| return self.fail(err);

    if (!model.matches(data, lock.lock.packages[@intCast(index)])) return null;

    const value = allocator.create(Manifest) catch |err| return self.fail(err);

    value.* = data;

    return @ptrCast(value);
}

pub fn borrowMember(handle: *const anyopaque, ordinal: u64, relative: []const u8) ?*const abi.PackageManifest {
    const self = host.Context.get(handle);
    const row = pkgs.workspace.manifest.memberAt(self.members, @intCast(ordinal), relative) orelse return null;

    return @ptrCast(&self.members[row].manifest);
}
