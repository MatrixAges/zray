const std = @import("std");
const pkgs = @import("pkgs");
const host = @import("../host.zig");
const Lock = pkgs.Lock;
const Manifest = @import("../../manifest/model.zig").Manifest;

const Declarations = struct {
    dependencies: @FieldType(Manifest, "dependencies"),
    dev_dependencies: @FieldType(Manifest, "dev_dependencies"),
    fn borrow(manifest: *const Manifest) Declarations {
        return .{ .dependencies = manifest.dependencies, .dev_dependencies = manifest.dev_dependencies };
    }
};

pub const State = struct {
    packages: std.ArrayList(Lock.Package) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    archive_declarations: std.ArrayList(Declarations) = .empty,
    archives: ?pkgs.install.Archives = null,
    resolver: pkgs.install.Resolver = undefined,
    index_base: []const u8 = undefined,
    dependencies: pkgs.install.Dependencies = undefined,
    owner_path: ?[]const u8 = null,
    pending: pkgs.install.Dependencies.Pending = undefined,
    lookup_view: @import("cli_abi").layouts.@"zig:installation_host".ArchiveLookup = undefined,
    archive_manifest: Manifest = undefined,
    spelling: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined,
};

pub fn prepareIndex(handle: *anyopaque) host.Error!void {
    const self = host.State.get(handle);
    const allocator = self.allocator;
    const options = self.options;

    const source = if (options.index) |path|
        std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| return self.fail(err)

    else
        @import("bundle").index;

    const parsed = pkgs.Index.parse(allocator, source) catch |err| return self.fail(err);
    const directory = if (options.index) |path| std.fs.path.dirname(path) orelse "." else ".";
    self.fresh.index_base = self.physicalPath(directory) catch |err| return self.fail(err);
    self.fresh.resolver = pkgs.install.Resolver.init(self.members, parsed.value);
    self.fresh.archives = .{ .allocator = allocator };

    self.fresh.packages.ensureTotalCapacity(allocator, self.members.len) catch |err| return self.fail(err);
    self.fresh.paths.ensureTotalCapacity(allocator, self.members.len) catch |err| return self.fail(err);
}

pub fn seedMember(handle: *anyopaque, index: u64) host.Error!void {
    const self = host.State.get(handle);
    const member = &self.members[@intCast(index)];
    const path = std.fs.path.resolve(self.allocator, &.{ self.root, member.path }) catch |err| return self.fail(err);

    self.fresh.packages.appendAssumeCapacity(.{
        .name = member.manifest.name,
        .version = member.manifest.version,
        .source = .{ .workspace = member.path },
        .dependencies = &.{},
    });

    self.fresh.paths.appendAssumeCapacity(self.physicalPath(path) catch |err| return self.fail(err));
}

pub fn packageCount(handle: *anyopaque) u64 {
    return host.State.get(handle).fresh.packages.items.len;
}

pub fn beginDependencies(handle: *anyopaque, index: u64, local: bool) void {
    const self = host.State.get(handle);
    const row: usize = @intCast(index);

    const declarations = if (local) member: {
        self.fresh.owner_path = self.members[row].path;

        break :member Declarations.borrow(&self.members[row].manifest);
    } else archive: {
        self.fresh.owner_path = null;

        break :archive self.fresh.archive_declarations.items[row - self.members.len];
    };

    self.fresh.dependencies.init(declarations);
}

pub fn advanceDependency(handle: *anyopaque, remaining: u64) host.Error!bool {
    const self = host.State.get(handle);
    const fresh = &self.fresh;
    fresh.pending = (fresh.dependencies.advance(self.allocator, &fresh.resolver, fresh.owner_path, @intCast(remaining)) catch |err| return self.fail(err)) orelse return false;

    return true;
}

pub fn acceptArchive(handle: *anyopaque, target: u64) void {
    host.State.get(handle).fresh.dependencies.accept(@intCast(target));
}

pub fn finishDependencies(handle: *anyopaque, index: u64) u64 {
    const fresh = &host.State.get(handle).fresh;
    const rows = fresh.dependencies.rows.items;

    fresh.packages.items[@intCast(index)].dependencies = rows;

    return rows.len;
}

pub fn finishFresh(handle: *anyopaque) host.Error!void {
    const self = host.State.get(handle);
    const allocator = self.allocator;

    const lock: Lock = .{
        .format_version = 1,
        .packages = self.fresh.packages.toOwnedSlice(allocator) catch |err| return self.fail(err),
    };

    lock.validate(allocator) catch |err| return self.fail(err);

    self.prepared = .{ .lock = lock, .paths = self.fresh.paths.toOwnedSlice(allocator) catch |err| return self.fail(err) };
}
