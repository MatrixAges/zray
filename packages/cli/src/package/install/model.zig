const std = @import("std");
const Lock = @import("pkgs").Lock;
const source = @import("../manifest/input.zig");
const Manifest = @import("../manifest/model.zig").Manifest;
const Inputs = @import("watch_inputs").Inputs;

pub const Prepared = struct { lock: Lock, paths: []const []const u8, source: ?[]const u8 = null };

pub fn read(io: std.Io, allocator: std.mem.Allocator, root: []const u8, inputs: ?*Inputs, manifests: std.mem.Allocator) !Manifest {
    const path = try std.fs.path.join(allocator, &.{ root, "pkg.yaml" });

    defer allocator.free(path);

    if (inputs) |observed| try observed.add(io, path);

    const parsed = try source.decode(io, manifests, .{ .path = path, .physical = path }, inputs);

    return switch (parsed) {
        .data => |data| data,
        .diagnostic => error.InvalidInstalledManifest,
    };
}

pub const matches = @import("pkgs").workspace.manifest.matches;
pub const matchesWorkspace = @import("pkgs").workspace.manifest.matchesWorkspace;
