const std = @import("std");
const pkgs = @import("pkgs");
const graph = @import("../../graph.zig");
const host = @import("../host.zig");

pub fn prepareWorkspace(handle: *anyopaque) host.Error!void {
    const self = host.State.get(handle);
    self.result.packages = self.allocator.alloc(graph.Package, self.members.len) catch |err| return self.fail(err);
    self.edges = self.allocator.alloc(graph.Dependency, @intCast(self.location.total)) catch |err| return self.fail(err);
}

pub fn localEdgeCount(handle: *anyopaque, index: u64) u64 {
    const data = &host.State.get(handle).members[@intCast(index)].manifest;

    return data.dependencies.len + data.dev_dependencies.len;
}

pub fn seedLocal(handle: *anyopaque, index: u64, first: u64, length: u64) host.Error!void {
    const self = host.State.get(handle);
    const member = &self.members[@intCast(index)];

    self.result.packages[@intCast(index)] = .{
        .path = self.allocator.dupe(u8, member.path) catch |err| return self.fail(err),
        .manifest = member.manifest,
        .dependencies = self.edges[@intCast(first)..][0..@intCast(length)],
    };
}

pub fn assembleWorkspace(handle: *anyopaque, shape: anytype) host.Error!@TypeOf(shape) {
    const self = host.State.get(handle);
    const output = self.result;
    const assembly = pkgs.graph.assemble(output.arena.child_allocator, output.root, output.packages, self.edges, self.location.capacity) catch |err| return self.fail(err);

    self.failed_owner = @intCast(assembly.owner);
    self.failed_edge = @intCast(assembly.edge);

    return switch (assembly.status) {
        inline else => |status| @field(@TypeOf(shape), @tagName(status)),
    };
}

pub fn failedOwner(handle: *anyopaque) u64 {
    return host.State.get(handle).failed_owner;
}

pub fn discardEdges(handle: *anyopaque, index: u64) void {
    host.State.get(handle).result.packages[@intCast(index)].dependencies = &.{};
}

pub fn reportWorkspace(handle: *anyopaque, message: []const u8, use_package_name: bool) host.Error!void {
    const self = host.State.get(handle);
    const owner = &self.result.packages[self.failed_owner];
    const data = &owner.manifest;
    const edge = self.failed_edge;
    const name = if (use_package_name) data.name else if (edge < data.dependencies.len) data.dependencies[edge].name else data.dev_dependencies[edge - data.dependencies.len].name;

    try self.report(owner.path, name, message);
}
