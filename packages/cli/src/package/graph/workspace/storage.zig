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
    const slice = allocator.create([]graph.Package) catch |err| return self.fail(err);
    const view = allocator.create(AssemblyOutcome) catch |err| return self.fail(err);
    slice.* = packages;

    view.* = .{
        .workspace = @ptrCast(slice),
        .status = switch (assembly.status) {
            inline else => |status| @field(WorkspaceStatus, @tagName(status)),
        },
        .failed_owner = assembly.owner,
        .owner_path = "",
        .owner_name = "",
        .edge_name = "",
    };

    switch (assembly.status) {
        .Valid, .InvalidVersion, .Overflow => {},
        else => {
            const owner = &packages[@intCast(assembly.owner)];
            const data = &owner.manifest;
            const edge: usize = @intCast(assembly.edge);
            view.owner_path = owner.path;
            view.owner_name = data.name;

            view.edge_name = switch (assembly.status) {
                .Duplicate, .InvalidSpecifier, .Missing, .InvalidRange, .LockVersionMismatch => if (edge < data.dependencies.len) data.dependencies[edge].name else data.dev_dependencies[edge - data.dependencies.len].name,
                else => "",
            };
        },
    }

    return view;
}
