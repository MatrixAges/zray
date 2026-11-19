const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rules = @import("cli_source");
const graph = @import("../graph.zig");
const Manifest = @import("../manifest/model.zig").Manifest;
const Package = compiler.project.Package;
const Scope = compiler.project.PackageScope;
const Input = std.meta.Child(rules.package_scope_bindings.Input);
const Output = std.meta.Child(@FieldType(Input, "output"));
const Target = memory.RowOutput(Package, Output, .{ .records = &.{}, .specifiers = &.{"specifier"} });
const root_export = rules.package_scope_constants.@"zx.constants".root_export;
const Surface = struct { bindings: []const Package };

pub fn bind(allocator: std.mem.Allocator, scratch: std.mem.Allocator, project: *const graph.Result, scopes: []Scope) !?[]const u8 {
    const surfaces = try scratch.alloc(Surface, scopes.len);

    for (project.packages, scopes, surfaces) |package, *scope, *surface| {
        const root = try std.fs.path.resolve(allocator, &.{ project.root, package.path });
        scope.* = .{ .root = root, .packages = &.{} };
        surface.* = .{ .bindings = try destinations(allocator, scratch, root, package.manifest) };
    }

    const bindings = memory.borrowSliceColumn(&.{"bindings"}, surfaces);
    const paths = memory.borrowListColumn([]const u8, "bindings", "specifier", surfaces);
    const targets = memory.borrowListColumn(usize, "dependencies", "target", project.packages);
    const aliases = memory.borrowListColumn([]const u8, "dependencies", "name", project.packages);

    for (project.packages, scopes, 0..) |package, *scope, owner| {
        var target: Target = undefined;

        target.init();

        const plan = zx.columns.invoke(rules.package_scope_bindings.executeValue, allocator, &Input{
            .owner = owner,
            .name = package.manifest.name,
            .targets = @ptrCast(&targets),
            .aliases = @ptrCast(&aliases),
            .bindings = @ptrCast(&bindings),
            .paths = @ptrCast(&paths),
            .width = @sizeOf(Package),
            .storage = @ptrCast(&target.buffer),
            .output = &target.view,
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        if (plan.missing) |index| {
            const edge = package.dependencies[@intCast(index)];
            const dependency = project.packages[edge.target].manifest;

            return try std.fmt.allocPrint(allocator, "{s}/pkg.yaml: dependency {s}: target {s} has no public modules", .{ scope.root, edge.name, dependency.name });
        }

        scope.packages = target.rows();
    }

    return null;
}

fn destinations(allocator: std.mem.Allocator, scratch: std.mem.Allocator, root: []const u8, manifest: Manifest) ![]const Package {
    const count = manifest.exports.len + @intFromBool(manifest.entry != null);
    const result = try scratch.alloc(Package, count);

    if (manifest.entry) |entry| {
        result[0] = .{ .specifier = root_export, .entry = try std.fs.path.resolve(allocator, &.{ root, entry }) };
    } else if (manifest.library) |library| {
        const artifact = try std.fs.path.resolve(allocator, &.{ root, library });

        for (manifest.exports, result) |item, *binding| binding.* = .{
            .specifier = item.path,
            .compiled = .{ .instance = root, .artifact = artifact, .name = item.module.? },
        };
    } else {
        for (manifest.exports, result) |item, *binding| binding.* = .{
            .specifier = item.path,
            .entry = try std.fs.path.resolve(allocator, &.{ root, item.source }),
        };
    }

    return result;
}
