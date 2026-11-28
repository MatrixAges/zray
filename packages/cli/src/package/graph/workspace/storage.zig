const std = @import("std");
const abi = @import("cli_abi");
const pkgs = @import("pkgs");
const graph = @import("../../graph.zig");
const host = @import("../host.zig");
const AssemblyOutcome = abi.layouts.@"zig:package_graph_host".AssemblyOutcome;
const WorkspaceStatus = abi.native.@"zig:package_graph_host".WorkspaceStatus;

pub fn assembleWorkspace(
    allocator: std.mem.Allocator,
    handle: *const anyopaque,
    root: []const u8,
    counts: []const u64,
    firsts: []const u64,
    total: u64,
) host.Error!*const AssemblyOutcome {
    const self = host.Context.get(handle);
    const packages = allocator.alloc(graph.Package, self.members.len) catch |err| return self.fail(err);
    const edges = allocator.alloc(graph.Dependency, @intCast(total)) catch |err| return self.fail(err);

    for (self.members, packages, counts, firsts) |member, *package, count, first| {
        package.* = .{
            .path = allocator.dupe(u8, member.path) catch |err| return self.fail(err),
            .manifest = member.manifest,
            .dependencies = edges[@intCast(first)..][0..@intCast(count)],
        };
    }

    const assembly = pkgs.graph.assemble(self.backing, root, packages, edges, 0) catch |err| return self.fail(err);
    const view = allocator.create(AssemblyOutcome) catch |err| return self.fail(err);
    self.workspace_packages = packages;

    view.* = .{
        .status = switch (assembly.status) {
            inline else => |status| @field(WorkspaceStatus, @tagName(status)),
        },
        .owner = assembly.owner,
        .edge = assembly.edge,
    };

    return view;
}
