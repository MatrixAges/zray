const std = @import("std");
const Inputs = @import("../cli/watch/inputs.zig");
const workspace = @import("workspace.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const pkgs = @import("pkgs");
pub const Dependency = struct { name: []const u8, target: usize, development: bool };
pub const Package = struct { path: []const u8, manifest: Manifest, dependencies: []const Dependency = &.{} };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    packages: []Package = &.{},
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    return loadWithInputs(io, allocator, path, null);
}

pub fn loadWithInputs(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs) !Result {
    var result: Result = .{ .arena = .init(allocator) };

    errdefer result.deinit();

    resolve(io, &result, path, inputs) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ path, @errorName(err) });
    };

    return result;
}

fn resolve(io: std.Io, result: *Result, path: []const u8, inputs: ?*Inputs) !void {
    const allocator = result.arena.allocator();
    const discovered = try workspace.loadWithInputs(io, allocator, path, inputs);

    if (discovered.diagnostic) |message| {
        result.diagnostic = message;

        return error.InvalidPackageGraph;
    }

    result.root = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", allocator);

    const location = pkgs.workspace.manifest.inspect(discovered.packages);

    if (location.found) {
        const package = discovered.packages[@intCast(location.row)];
        const entries = if (location.development) package.manifest.dev_dependencies else package.manifest.dependencies;

        result.packages = @import("installed.zig").load(io, allocator, result.root, discovered.packages, inputs) catch |err| {
            if (err == error.PackagesNotInstalled) result.diagnostic = try std.fmt.allocPrint(allocator, "{s}/pkg.yaml: dependency {s}: external dependency is not installed; run zxc pkg install", .{ package.path, entries[@intCast(location.edge)].name });

            return err;
        };

        return;
    }

    result.packages = try allocator.alloc(Package, discovered.packages.len);
    const edges = try allocator.alloc(Dependency, @intCast(location.total));
    var offset: usize = 0;

    for (discovered.packages, result.packages) |source, *package| {
        const length = source.manifest.dependencies.len + source.manifest.dev_dependencies.len;
        package.* = .{ .path = source.path, .manifest = source.manifest, .dependencies = edges[offset..][0..length] };
        offset += length;
    }

    const graph = try pkgs.graph.assemble(result.arena.child_allocator, result.root, result.packages, edges, location.capacity);

    if (graph.status == .Valid) return;

    const owner: usize = @intCast(graph.owner);
    const data = result.packages[owner].manifest;

    switch (graph.status) {
        .CyclicPackageDependencies => return fail(result, owner, data.name, "package dependencies must be acyclic"),
        .PackageDependencyDepthExceeded => return fail(result, owner, data.name, "package dependency depth exceeds 256"),
        else => {},
    }

    for (result.packages[owner..]) |*package| package.dependencies = &.{};

    const edge: usize = @intCast(graph.edge);
    const name = if (edge < data.dependencies.len) data.dependencies[edge].name else data.dev_dependencies[edge - data.dependencies.len].name;

    return switch (graph.status) {
        .Duplicate => fail(result, owner, name, "dependency appears in both dependencies and dev_dependencies"),
        .InvalidSpecifier => fail(result, owner, name, "workspace alias requires a package name and version range"),
        .Missing => fail(result, owner, name, "workspace dependency has no matching local package"),
        .InvalidRange => fail(result, owner, name, "invalid workspace version range"),
        .LockVersionMismatch => fail(result, owner, name, "workspace package version does not satisfy the dependency range"),
        .InvalidVersion => error.InvalidVersion,
        .Overflow => error.Overflow,
        .Valid, .CyclicPackageDependencies, .PackageDependencyDepthExceeded => unreachable,
    };
}

fn fail(result: *Result, owner: usize, name: []const u8, message: []const u8) error{ OutOfMemory, InvalidPackageGraph } {
    result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}/pkg.yaml: dependency {s}: {s}", .{ result.packages[owner].path, name, message });

    return error.InvalidPackageGraph;
}
