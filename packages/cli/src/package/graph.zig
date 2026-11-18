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

    for (discovered.packages) |package| {
        for ([_][]const @import("manifest/model.zig").Dependency{ package.manifest.dependencies, package.manifest.dev_dependencies }) |entries| {
            for (entries) |entry| {
                if (pkgs.workspace.parse(entry.name, entry.requirement) != .external) continue;

                result.packages = @import("installed.zig").load(io, allocator, result.root, discovered.packages, inputs) catch |err| {
                    if (err == error.PackagesNotInstalled) result.diagnostic = try std.fmt.allocPrint(allocator, "{s}/pkg.yaml: dependency {s}: external dependency is not installed; run zxc pkg install", .{ package.path, entry.name });

                    return err;
                };

                return;
            }
        }
    }

    result.packages = try allocator.alloc(Package, discovered.packages.len);

    for (discovered.packages, result.packages) |source, *package| package.* = .{ .path = source.path, .manifest = source.manifest };

    for (result.packages, 0..) |*package, owner| {
        var dependencies: std.ArrayList(Dependency) = .empty;

        for ([_][]const @import("manifest/model.zig").Dependency{ package.manifest.dependencies, package.manifest.dev_dependencies }, 0..) |entries, kind| {
            for (entries) |entry| {
                for (dependencies.items) |previous| {
                    if (std.mem.eql(u8, previous.name, entry.name)) return fail(result, owner, entry.name, "dependency appears in both dependencies and dev_dependencies");
                }

                const target = try dependency(result, owner, entry.name, entry.requirement);

                try dependencies.append(allocator, .{ .name = entry.name, .target = target, .development = kind == 1 });
            }
        }

        package.dependencies = try dependencies.toOwnedSlice(allocator);
    }

    const graph = try pkgs.graph.check(allocator, result.packages, .workspace);
    const owner: usize = @intCast(graph.owner);

    switch (graph.status) {
        .Valid => {},
        .CyclicPackageDependencies => return fail(result, owner, result.packages[owner].manifest.name, "package dependencies must be acyclic"),
        .PackageDependencyDepthExceeded => return fail(result, owner, result.packages[owner].manifest.name, "package dependency depth exceeds 256"),
        .UnreachableLockPackage => unreachable,
    }
}

fn dependency(result: *Result, owner: usize, name: []const u8, requirement: []const u8) !usize {
    const spec = pkgs.workspace.parse(name, requirement);

    const target_path = switch (spec) {
        .external => return fail(result, owner, name, "external dependency is not installed; run zxc pkg install"),
        .invalid => return fail(result, owner, name, "workspace alias requires a package name and version range"),
        .path => |text| try std.fs.path.resolve(result.arena.allocator(), &.{ result.root, result.packages[owner].path, text }),
        .named => null,
    };

    for (result.packages, 0..) |package, index| {
        const matches = if (target_path) |path| std.mem.eql(u8, path, try std.fs.path.resolve(result.arena.allocator(), &.{ result.root, package.path })) else std.mem.eql(u8, package.manifest.name, spec.named.name);

        if (!matches) continue;

        if (spec == .named) if (spec.named.range) |range| {
            const accepted = pkgs.version.matches(range, try std.SemanticVersion.parse(package.manifest.version)) catch return fail(result, owner, name, "invalid workspace version range");

            if (!accepted) return fail(result, owner, name, "workspace package version does not satisfy the dependency range");
        };

        return index;
    }

    return fail(result, owner, name, "workspace dependency has no matching local package");
}

fn fail(result: *Result, owner: usize, name: []const u8, message: []const u8) error{ OutOfMemory, InvalidPackageGraph } {
    result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}/pkg.yaml: dependency {s}: {s}", .{ result.packages[owner].path, name, message });

    return error.InvalidPackageGraph;
}
