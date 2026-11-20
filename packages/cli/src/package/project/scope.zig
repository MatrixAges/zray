const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rules = @import("cli_source");
const graph = @import("../graph.zig");
const effects = @import("../../cli/sources/effects.zig");
const Error = effects.Error;
const Package = compiler.project.Package;
const Scope = compiler.project.PackageScope;
const Input = std.meta.Child(rules.package_scope_bindings.Input);
const Output = std.meta.Child(@FieldType(Input, "output"));
const Target = memory.RowOutput(Package, Output, .{ .records = &.{}, .specifiers = &.{"specifier"} });
const root_export = rules.package_scope_constants.@"zx.constants".root_export;
const Surface = struct { bindings: []Package };

const State = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    graph: *const graph.Result,
    scopes: []Scope,
    surfaces: []Surface,
    current: usize = undefined,
    compiled_path: []const u8 = undefined,
    bindings: memory.ListColumn = undefined,
    paths: memory.ListColumn = undefined,
    dependencies: graph.DependencyColumns = undefined,
    diagnostic: ?[]const u8 = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn root(self: *const State) []const u8 {
        return self.scopes[self.current].root;
    }
    fn destination(self: *State, index: usize) *Package {
        return &self.surfaces[self.current].bindings[index];
    }
};

pub fn bind(allocator: std.mem.Allocator, scratch: std.mem.Allocator, project: *const graph.Result, scopes: []Scope) !?[]const u8 {
    var state: State = .{
        .allocator = allocator,
        .scratch = scratch,
        .graph = project,
        .scopes = scopes,
        .surfaces = try scratch.alloc(Surface, scopes.len),
    };

    const reference = &state;

    rules.workspace_scope_bind.executeValue(scratch, &.{ .binding = @ptrCast(&reference), .count = scopes.len }) catch |err| return state.failure.unwrap(err);

    return state.diagnostic;
}

pub fn prepareSurface(handle: *const anyopaque, row: u64) Error!u64 {
    const self = State.get(handle);
    const index: usize = @intCast(row);
    const package = &self.graph.packages[index];
    const root = std.fs.path.resolve(self.allocator, &.{ self.graph.root, package.path }) catch |err| return self.failure.save(err);
    const count = package.manifest.exports.len + @intFromBool(package.manifest.entry != null);
    const items = self.scratch.alloc(Package, count) catch |err| return self.failure.save(err);

    self.current = index;
    self.scopes[index] = .{ .root = root, .packages = &.{} };
    self.surfaces[index] = .{ .bindings = items };

    return package.manifest.exports.len;
}

pub fn scopeEntry(handle: *const anyopaque) ?[]const u8 {
    const self = State.get(handle);

    return self.graph.packages[self.current].manifest.entry;
}

pub fn scopeLibrary(handle: *const anyopaque) ?[]const u8 {
    const self = State.get(handle);

    return self.graph.packages[self.current].manifest.library;
}

pub fn writeScopeEntry(handle: *const anyopaque, entry: []const u8) Error!void {
    const self = State.get(handle);
    const path = std.fs.path.resolve(self.allocator, &.{ self.root(), entry }) catch |err| return self.failure.save(err);

    self.destination(0).* = .{ .specifier = root_export, .entry = path };
}

pub fn prepareLibrarySurface(handle: *const anyopaque, library: []const u8) Error!void {
    const self = State.get(handle);

    self.compiled_path = std.fs.path.resolve(self.allocator, &.{ self.root(), library }) catch |err| return self.failure.save(err);
}

pub fn writeCompiledExport(handle: *const anyopaque, index: u64) void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const item = &self.graph.packages[self.current].manifest.exports[row];

    self.destination(row).* = .{ .specifier = item.path, .compiled = .{ .instance = self.root(), .artifact = self.compiled_path, .name = item.module.? } };
}

pub fn writeSourceExport(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const item = &self.graph.packages[self.current].manifest.exports[row];
    const path = std.fs.path.resolve(self.allocator, &.{ self.root(), item.source }) catch |err| return self.failure.save(err);

    self.destination(row).* = .{ .specifier = item.path, .entry = path };
}

pub fn borrowScopeColumns(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.bindings = memory.borrowSliceColumn(&.{"bindings"}, self.surfaces);
    self.paths = memory.borrowListColumn([]const u8, "bindings", "specifier", self.surfaces);
    self.dependencies = self.graph.dependencyColumns();
}

pub fn bindScope(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const owner: usize = @intCast(index);
    const package = &self.graph.packages[owner];
    const scope = &self.scopes[owner];
    var target: Target = undefined;

    target.init();

    const plan = zx.columns.invoke(rules.package_scope_bindings.executeValue, self.allocator, &Input{
        .owner = owner,
        .name = package.manifest.name,
        .targets = @ptrCast(&self.dependencies.targets),
        .aliases = @ptrCast(&self.dependencies.names),
        .bindings = @ptrCast(&self.bindings),
        .paths = @ptrCast(&self.paths),
        .width = @sizeOf(Package),
        .storage = @ptrCast(&target.buffer),
        .output = &target.view,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return self.failure.save(error.OutOfMemory),
        else => unreachable,
    };

    if (plan.missing) |edge_index| {
        const edge = self.graph.dependency(owner, @intCast(edge_index));
        const name = self.graph.packages[edge.target].manifest.name;

        self.diagnostic = std.fmt.allocPrint(self.allocator, "{s}/pkg.yaml: dependency {s}: target {s} has no public modules", .{ scope.root, edge.name, name }) catch |err| return self.failure.save(err);

        return false;
    }

    scope.packages = target.rows();

    return true;
}
