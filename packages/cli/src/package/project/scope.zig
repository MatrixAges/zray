const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rules = @import("cli_source");
const graph = @import("../graph.zig");
const Error = @import("../../cli/sources/effects.zig").Error;
const State = @import("../project.zig").State;
const Package = compiler.project.Package;
const Input = std.meta.Child(rules.package_scope_bindings.Input);
const Surface = struct { bindings: []Package };
const abi = @import("cli_abi").layouts.@"zig:package_workspace_host";

pub const Storage = struct {
    surfaces: []Surface,
    paths: memory.ListColumn,
    dependencies: graph.DependencyColumns,
    pub fn init(scratch: std.mem.Allocator, project: *const graph.Result) !Storage {
        const surfaces = try scratch.alloc(Surface, project.packages.len);

        return .{
            .surfaces = surfaces,
            .paths = memory.borrowListColumn([]const u8, "bindings", "specifier", surfaces),
            .dependencies = project.dependencyColumns(),
        };
    }
};

pub fn readScopeSurface(handle: *const anyopaque, row: u64) Error!*const abi.Surface {
    const self = State.get(handle);
    const package = &self.graph.?.packages[@intCast(row)];
    const exports = package.manifest.exports;
    const values = self.scratch.alloc(abi.SurfaceExport, exports.len) catch |err| return self.failure.save(err);
    const references = self.scratch.alloc(*const abi.SurfaceExport, exports.len) catch |err| return self.failure.save(err);
    const view = self.scratch.create(abi.Surface) catch |err| return self.failure.save(err);

    for (exports, values, references) |item, *value, *reference| {
        value.* = .{ .specifier = item.path, .source = item.source, .module = item.module };
        reference.* = value;
    }

    view.* = .{
        .root = self.graph.?.root,
        .path = package.path,
        .exports = references,
        .entry = package.manifest.entry,
        .library = package.manifest.library,
    };

    return view;
}

pub fn publishScopeSurface(handle: *const anyopaque, index: u64, surface: *const abi.PublishedSurface) Error!void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const root = self.allocator.dupe(u8, surface.root) catch |err| return self.failure.save(err);
    const items = self.scratch.alloc(Package, surface.rows.len) catch |err| return self.failure.save(err);
    const artifact = if (surface.artifact) |path| self.allocator.dupe(u8, path) catch |err| return self.failure.save(err) else null;

    for (surface.rows, items) |entry, *package| {
        package.* = if (artifact) |path|
            .{ .specifier = entry.specifier, .compiled = .{ .instance = root, .artifact = path, .name = entry.module.? } }

        else
            .{ .specifier = entry.specifier, .entry = self.allocator.dupe(u8, entry.source) catch |err| return self.failure.save(err) };
    }

    self.scopes[row] = .{ .root = root, .packages = &.{} };
    self.binding.surfaces[row] = .{ .bindings = items };
}

pub fn bindScope(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const owner: usize = @intCast(index);
    const package = &self.graph.?.packages[owner];
    const scope = &self.scopes[owner];

    const plan = zx.columns.invoke(rules.package_scope_bindings.executeValue, self.scratch, &Input{
        .owner = owner,
        .name = package.manifest.name,
        .targets = @ptrCast(&self.binding.dependencies.targets),
        .aliases = @ptrCast(&self.binding.dependencies.names),
        .paths = @ptrCast(&self.binding.paths),
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return self.failure.save(error.OutOfMemory),
        else => unreachable,
    };

    if (plan.missing) |edge_index| {
        const edge = self.graph.?.dependency(owner, @intCast(edge_index));
        const name = self.graph.?.packages[edge.target].manifest.name;
        self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}/pkg.yaml: dependency {s}: target {s} has no public modules", .{ scope.root, edge.name, name }) catch |err| return self.failure.save(err);

        return false;
    }

    const packages = self.allocator.alloc(Package, plan.entries.len) catch |err| return self.failure.save(err);

    for (plan.entries, packages) |entry, *out| {
        var copied = self.binding.surfaces[@intCast(entry.target)].bindings[@intCast(entry.row)];
        copied.specifier = self.allocator.dupe(u8, entry.specifier) catch |err| return self.failure.save(err);
        out.* = copied;
    }

    scope.packages = packages;

    return true;
}
