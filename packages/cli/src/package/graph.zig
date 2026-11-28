const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const workspace = @import("workspace.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const pkgs = @import("pkgs");
const memory = @import("zx").memory;
pub const Dependency = struct { name: []const u8, target: usize, development: bool };
pub const DependencyColumns = struct { targets: memory.ListColumn, names: memory.ListColumn };
pub const Package = struct { path: []const u8, manifest: Manifest, dependencies: []const Dependency = &.{} };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    packages: []Package = &.{},
    locked: ?[]const pkgs.Lock.Package = null,
    diagnostic: ?[]const u8 = null,
    pub fn dependency(self: *const Result, owner: usize, index: usize) Dependency {
        if (self.locked) |locked| {
            const edge = &locked[owner].dependencies[index];

            return .{ .name = edge.name, .target = edge.target, .development = edge.development };
        }

        return self.packages[owner].dependencies[index];
    }

    pub fn dependencyColumns(self: *const Result) DependencyColumns {
        return if (self.locked) |locked| .{
            .targets = memory.borrowListColumn(usize, "dependencies", "target", locked),
            .names = memory.borrowListColumn([]const u8, "dependencies", "name", locked),
        } else .{
            .targets = memory.borrowListColumn(usize, "dependencies", "target", self.packages),
            .names = memory.borrowListColumn([]const u8, "dependencies", "name", self.packages),
        };
    }

    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    return loadPrepared(io, allocator, .{ .path = path }, null);
}

pub fn loadPrepared(io: std.Io, allocator: std.mem.Allocator, request: workspace.Request, members: ?*const workspace.Result) !Result {
    var result: Result = .{ .arena = .init(allocator) };

    errdefer result.deinit();

    resolve(io, &result, request, members) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ request.path, @errorName(err) });
    };

    return result;
}

fn resolve(io: std.Io, result: *Result, original: workspace.Request, captured: ?*const workspace.Result) !void {
    const allocator = result.arena.allocator();
    const manifests = original.manifests orelse allocator;
    var fresh: ?workspace.Result = null;

    defer if (fresh) |*snapshot| snapshot.deinit();

    const discovered = captured orelse block: {
        var request = original;
        request.manifests = manifests;
        fresh = try workspace.loadPrepared(io, result.arena.child_allocator, request);

        break :block &fresh.?;
    };

    if (discovered.diagnostic) |message| {
        result.diagnostic = try allocator.dupe(u8, message);

        return error.InvalidPackageGraph;
    }

    result.root = try allocator.dupe(u8, discovered.root);

    const host = @import("graph/host.zig");
    const location = pkgs.workspace.manifest.inspect(discovered.packages);
    const missing = if (location.found) &discovered.packages[@intCast(location.row)] else null;

    const missing_name = if (missing) |member| label: {
        const declarations = if (location.development) member.manifest.dev_dependencies else member.manifest.dependencies;

        break :label declarations[@intCast(location.edge)].name;
    } else "";

    var failure: ?anyerror = null;

    var context: host.Context = .{
        .io = io,
        .members = discovered.packages,
        .inputs = original.inputs,
        .manifests = manifests,
        .backing = result.arena.child_allocator,
        .failure = &failure,
    };

    const reference = &context;
    const member_paths = memory.borrowTextColumn("path", discovered.packages);
    const declarations = pkgs.workspace.manifest.Manifests.borrow(&.{"manifest"}, discovered.packages);

    const outcome = @import("cli_source").graph_load.executeIn(allocator, &.{
        .graph = @ptrCast(&reference),
        .member_paths = @ptrCast(&member_paths),
        .member_count = discovered.packages.len,
        .root = result.root,
        .external = location.found,
        .missing_path = if (missing) |member| member.path else "",
        .missing_name = missing_name,
        .declarations = &.{
            .names = @ptrCast(&declarations.names),
            .production = @ptrCast(&declarations.production_names),
            .development = @ptrCast(&declarations.development_names),
        },
    }, io) catch |err| switch (err) {
        error.PackageGraphHostFailure => return failure.?,
        else => return err,
    };

    result.diagnostic = outcome.diagnostic;

    if (context.workspace_packages) |packages| {
        result.packages = packages;

        if (outcome.keep_rows) |count| {
            for (packages[@intCast(count)..]) |*package| package.dependencies = &.{};
        }
    }

    if (outcome.installed) |installed| {
        const packages = context.installed;

        for (installed, packages) |row, *package| {
            if (row.member) |member| {
                package.* = .{ .path = row.path, .manifest = discovered.packages[@intCast(member)].manifest };
            }
        }

        result.packages = packages;
        result.locked = context.lock.?.lock.packages;
    }

    switch (outcome.status) {
        .Valid => {},
        .PackagesNotInstalled => return error.PackagesNotInstalled,
        .LockFileOutdated => return error.LockFileOutdated,
        .InvalidPackageInstallation => return error.InvalidPackageInstallation,
        .InstalledManifestDoesNotMatchLock => return error.InstalledManifestDoesNotMatchLock,
        .InvalidPackageGraph => return error.InvalidPackageGraph,
        .InvalidVersion => return error.InvalidVersion,
        .Overflow => return error.Overflow,
    }
}
