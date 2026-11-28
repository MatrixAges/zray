const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const compiler = @import("compiler");
const discover = @import("discover.zig");
const graph = @import("graph.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;
const rules = @import("cli_source");
pub const scope = @import("project/scope.zig");

pub const Result = struct {
    scopes: []compiler.project.PackageScope = &.{},
    manifests: []const Manifest = &.{},
    entry: ?[]const u8 = null,
    owner: ?usize = null,
    diagnostic: ?[]const u8 = null,
};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    entry: []const u8,
    inputs: ?*Inputs,
    discovered: discover.Result = .{},
    graph: ?graph.Result = null,
    scopes: []compiler.project.PackageScope = &.{},
    binding: scope.Storage = undefined,
    real: []const u8 = undefined,
    result: Result = .{},
    failure: effects.Failure = .{},
    pub fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

pub fn loadWithInputs(io: std.Io, allocator: std.mem.Allocator, scratch: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8, inputs: ?*Inputs) !Result {
    var state: State = .{
        .io = io,
        .allocator = allocator,
        .scratch = scratch,
        .entry = entry,
        .inputs = inputs,
    };

    defer state.discovered.deinit();
    defer if (state.graph) |*loaded| loaded.deinit();

    const reference = &state;

    const outcome = rules.workspace_project.executeIn(scratch, &.{
        .project = @ptrCast(&reference),
        .config_path = config_path,
    }) catch |err| return state.failure.unwrap(err);

    if (outcome.owner) |owner| {
        try publishProject(&state, owner);
    } else if (outcome.outside_package) {
        state.result.diagnostic = rules.workspace_project_constants.@"zx.constants".outside_package;
    }

    return state.result;
}

pub fn findProjectConfiguration(handle: *const anyopaque) Error!?[]const u8 {
    const self = State.get(handle);

    self.discovered = discover.findWithInputs(self.io, self.scratch, self.allocator, self.entry, self.inputs) catch |err| return self.failure.save(err);

    if (self.discovered.diagnostic) |message| {
        self.result.diagnostic = self.allocator.dupe(u8, message) catch |err| return self.failure.save(err);

        return null;
    }

    return self.discovered.path;
}

pub fn loadProjectGraph(handle: *const anyopaque, path: []const u8) Error!?u64 {
    const self = State.get(handle);

    self.graph = graph.loadPrepared(self.io, std.heap.smp_allocator, .{
        .path = path,
        .inputs = self.inputs,
        .manifests = self.allocator,
        .root = self.discovered.root,
    }, if (self.discovered.members) |*members| members else null) catch |err| return self.failure.save(err);

    if (self.graph.?.diagnostic) |message| {
        self.result.diagnostic = self.allocator.dupe(u8, message) catch |err| return self.failure.save(err);

        return null;
    }

    const project = &self.graph.?;

    self.scopes = self.allocator.alloc(compiler.project.PackageScope, project.packages.len) catch |err| return self.failure.save(err);
    self.binding = scope.Storage.init(self.scratch, project) catch |err| return self.failure.save(err);

    return self.scopes.len;
}

pub fn owningProjectScope(handle: *const anyopaque) Error!?u64 {
    const self = State.get(handle);

    self.real = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.entry, self.allocator) catch |err| return self.failure.save(err);

    return compiler.project.package_scope.owner(self.scopes, self.real);
}

fn publishProject(self: *State, owner: u64) !void {
    const manifests = try self.scratch.alloc(Manifest, self.scopes.len);

    for (self.graph.?.packages, manifests) |package, *manifest| manifest.* = package.manifest;

    self.result = .{ .scopes = self.scopes, .manifests = manifests, .entry = self.real, .owner = @intCast(owner) };
}
