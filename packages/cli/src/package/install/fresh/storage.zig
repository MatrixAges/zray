const std = @import("std");
const pkgs = @import("pkgs");
const host = @import("../host.zig");
const Lock = pkgs.Lock;
const Manifest = @import("../../manifest/model.zig").Manifest;
const abi = @import("cli_abi").layouts.@"zig:installation_host";

const Declarations = struct {
    dependencies: @FieldType(Manifest, "dependencies"),
    dev_dependencies: @FieldType(Manifest, "dev_dependencies"),
    fn borrow(manifest: *const Manifest) Declarations {
        return .{ .dependencies = manifest.dependencies, .dev_dependencies = manifest.dev_dependencies };
    }
};

pub const State = struct {
    session: *host.Context,
    packages: std.ArrayList(Lock.Package) = .empty,
    archive_declarations: std.ArrayList(Declarations) = .empty,
    archives: pkgs.install.Archives,
    resolver: pkgs.install.Resolver,
    dependencies: pkgs.install.Dependencies = undefined,
    owner_path: ?[]const u8 = null,
    archive_manifest: Manifest = undefined,
    archive_identity: abi.ArchiveIdentity = undefined,
    handle: *State = undefined,
    pub fn get(handle: *const anyopaque) *State {
        const reference: *const *State = @ptrCast(@alignCast(handle));

        return reference.*;
    }
};

pub fn prepareIndex(handle: *const anyopaque) host.Error!*const abi.Catalog {
    const session = host.Context.get(handle);
    const allocator = session.allocator;
    const options = session.options;

    const source = if (options.index) |path|
        std.Io.Dir.cwd().readFileAlloc(session.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| return session.fail(err)

    else
        @import("bundle").index;

    const parsed = pkgs.Index.parse(allocator, source) catch |err| return session.fail(err);
    const directory = if (options.index) |path| std.fs.path.dirname(path) orelse "." else ".";
    const index_base = session.physicalPath(directory) catch |err| return session.fail(err);
    const fresh = allocator.create(State) catch |err| return session.fail(err);
    const view = allocator.create(abi.Catalog) catch |err| return session.fail(err);

    fresh.* = .{
        .session = session,
        .resolver = pkgs.install.Resolver.init(session.members, parsed.value),
        .archives = .{ .allocator = allocator },
        .handle = fresh,
    };

    fresh.packages.ensureTotalCapacity(allocator, session.members.len) catch |err| return session.fail(err);

    view.* = .{ .build = @ptrCast(&fresh.handle), .index_base = index_base };

    return view;
}

pub fn seedMember(handle: *const anyopaque, index: u64) host.Error![]const u8 {
    const fresh = State.get(handle);
    const session = fresh.session;
    const member = &session.members[@intCast(index)];
    const path = std.fs.path.resolve(session.allocator, &.{ session.root, member.path }) catch |err| return session.fail(err);

    fresh.packages.appendAssumeCapacity(.{
        .name = member.manifest.name,
        .version = member.manifest.version,
        .source = .{ .workspace = member.path },
        .dependencies = &.{},
    });

    return session.physicalPath(path) catch |err| session.fail(err);
}

pub fn beginDependencies(handle: *const anyopaque, index: u64, local: bool) void {
    const fresh = State.get(handle);
    const members = fresh.session.members;
    const row: usize = @intCast(index);

    const declarations = if (local) member: {
        fresh.owner_path = members[row].path;

        break :member Declarations.borrow(&members[row].manifest);
    } else archive: {
        fresh.owner_path = null;

        break :archive fresh.archive_declarations.items[row - members.len];
    };

    fresh.dependencies.init(declarations);
}

pub fn advanceDependency(handle: *const anyopaque, remaining: u64) host.Error!?*const abi.Release {
    const fresh = State.get(handle);
    const session = fresh.session;
    const allocator = session.allocator;
    const pending = (fresh.dependencies.advance(allocator, &fresh.resolver, fresh.owner_path, @intCast(remaining)) catch |err| return session.fail(err)) orelse return null;
    const release = pending.release;
    const view = allocator.create(abi.Release) catch |err| return session.fail(err);
    var spelling: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    const lower = std.ascii.lowerString(&spelling, release.sha256);
    const digest = if (std.mem.eql(u8, lower, release.sha256)) release.sha256 else allocator.dupe(u8, lower) catch |err| return session.fail(err);

    view.* = .{ .name = pending.name, .version = release.version, .archive = release.archive, .sha256 = digest };

    return view;
}

pub fn acceptArchive(handle: *const anyopaque, target: u64) void {
    State.get(handle).dependencies.accept(@intCast(target));
}

pub fn finishDependencies(handle: *const anyopaque, index: u64) u64 {
    const fresh = State.get(handle);
    const rows = fresh.dependencies.rows.items;

    fresh.packages.items[@intCast(index)].dependencies = rows;

    return rows.len;
}

pub fn finishFresh(handle: *const anyopaque) host.Error!void {
    const fresh = State.get(handle);
    const session = fresh.session;
    const allocator = session.allocator;

    const lock: Lock = .{
        .format_version = 1,
        .packages = fresh.packages.toOwnedSlice(allocator) catch |err| return session.fail(err),
    };

    lock.validate(allocator) catch |err| return session.fail(err);

    session.lock = .{ .lock = lock };
}
