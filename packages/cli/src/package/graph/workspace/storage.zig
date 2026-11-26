const std = @import("std");
const abi = @import("cli_abi");
const pkgs = @import("pkgs");
const graph = @import("../../graph.zig");
const host = @import("../host.zig");
const AssemblyOutcome = abi.layouts.@"zig:package_graph_host".AssemblyOutcome;
const WorkspaceStatus = abi.native.@"zig:package_graph_host".WorkspaceStatus;

pub fn prepareWorkspace(handle: *anyopaque) host.Error![]const u64 {
    const self = host.State.get(handle);
    const edge_counts = self.allocator.alloc(u64, self.members.len) catch |err| return self.fail(err);
    self.result.packages = self.allocator.alloc(graph.Package, self.members.len) catch |err| return self.fail(err);
    self.edges = self.allocator.alloc(graph.Dependency, @intCast(self.location.total)) catch |err| return self.fail(err);

    for (self.members, 0..) |member, index| {
        const data = &member.manifest;

        edge_counts[index] = data.dependencies.len + data.dev_dependencies.len;
    }

    return edge_counts;
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

pub fn assembleWorkspace(handle: *anyopaque) host.Error!*const AssemblyOutcome {
    const self = host.State.get(handle);
    const output = self.result;
    const assembly = pkgs.graph.assemble(output.arena.child_allocator, output.root, output.packages, self.edges, self.location.capacity) catch |err| return self.fail(err);

    self.failed_owner = @intCast(assembly.owner);
    self.failed_edge = @intCast(assembly.edge);

    self.assembly_view = .{
        .status = switch (assembly.status) {
            inline else => |status| @field(WorkspaceStatus, @tagName(status)),
        },
        .failed_owner = self.failed_owner,
    };

    return &self.assembly_view;
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
