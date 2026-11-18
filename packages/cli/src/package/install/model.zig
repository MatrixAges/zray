const std = @import("std");
const Lock = @import("pkgs").Lock;
const manifest = @import("../manifest.zig");
const Manifest = @import("../manifest/model.zig").Manifest;
const Inputs = @import("../../cli/watch/inputs.zig");

pub const Prepared = struct { lock: Lock, paths: []const []const u8, source: ?[]const u8 = null };

pub fn read(io: std.Io, allocator: std.mem.Allocator, root: []const u8, inputs: ?*Inputs) !Manifest {
    const path = try std.fs.path.join(allocator, &.{ root, "pkg.yaml" });

    if (inputs) |observed| try observed.add(io, path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));

    if (inputs) |observed| try observed.record(io, path, source);

    const parsed = try manifest.parse(allocator, source);

    return switch (parsed.value) {
        .data => |data| data,
        .diagnostic => error.InvalidInstalledManifest,
    };
}

pub const matches = @import("pkgs").workspace.manifest.matches;
pub const matchesWorkspace = @import("pkgs").workspace.manifest.matchesWorkspace;
