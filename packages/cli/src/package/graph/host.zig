const std = @import("std");
const pkgs = @import("pkgs");
const graph = @import("../graph.zig");
const workspace = @import("../workspace.zig");
const files = @import("../install/files.zig");
const Manifest = @import("../manifest/model.zig").Manifest;
const Inputs = @import("watch_inputs").Inputs;
pub const isAbsolute = std.fs.path.isAbsolute;
pub const parent = std.fs.path.dirname;
pub const basename = std.fs.path.basename;
pub const Error = error{PackageGraphHostFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    result: *graph.Result,
    members: []const workspace.Package,
    inputs: ?*Inputs,
    manifests: std.mem.Allocator,
    location: pkgs.workspace.manifest.Location,
    locked: files.Loaded = undefined,
    mapping: files.Mapping = undefined,
    installed_packages: []graph.Package = &.{},
    archive: Manifest = undefined,
    edges: []graph.Dependency = &.{},
    failed_owner: usize = undefined,
    failed_edge: usize = undefined,
    failure: ?anyerror = null,
    pub fn get(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }

    pub fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.PackageGraphHostFailure;
    }
    pub fn report(self: *State, path: []const u8, name: []const u8, message: []const u8) Error!void {
        self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}/pkg.yaml: dependency {s}: {s}", .{ path, name, message }) catch |err| return self.fail(err);
    }
};

pub fn reportMissing(handle: *anyopaque, message: []const u8) Error!void {
    const self = State.get(handle);
    const location = self.location;
    const member = &self.members[@intCast(location.row)];
    const entries = if (location.development) member.manifest.dev_dependencies else member.manifest.dependencies;

    try self.report(member.path, entries[@intCast(location.edge)].name, message);
}
