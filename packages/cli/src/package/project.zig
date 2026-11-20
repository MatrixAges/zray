const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const compiler = @import("compiler");
const discover = @import("discover.zig");
const graph = @import("graph.zig");
const Manifest = @import("manifest/model.zig").Manifest;

pub const Result = struct {
    scopes: []compiler.project.PackageScope = &.{},
    manifests: []const Manifest = &.{},
    entry: ?[]const u8 = null,
    owner: ?usize = null,
    diagnostic: ?[]const u8 = null,
};

pub fn loadWithInputs(io: std.Io, allocator: std.mem.Allocator, scratch: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8, inputs: ?*Inputs) !Result {
    var discovered = if (config_path) |path| discover.Result{ .path = path } else try discover.findWithInputs(io, scratch, allocator, entry, inputs);

    defer discovered.deinit();

    if (discovered.diagnostic) |message| return .{ .diagnostic = try allocator.dupe(u8, message) };

    const path = discovered.path orelse return .{};

    var resolved = try graph.loadPrepared(io, std.heap.smp_allocator, .{
        .path = path,
        .inputs = inputs,
        .manifests = allocator,
        .root = discovered.root,
    }, if (discovered.members) |*members| members else null);

    defer resolved.deinit();

    if (resolved.diagnostic) |message| return .{ .diagnostic = try allocator.dupe(u8, message) };

    const scopes = try allocator.alloc(compiler.project.PackageScope, resolved.packages.len);

    if (try @import("project/scope.zig").bind(allocator, scratch, &resolved, scopes)) |message| return .{ .diagnostic = message };

    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, entry, allocator);
    const owner = compiler.project.package_scope.owner(scopes, real) orelse return .{ .diagnostic = "entry file is outside the configured package" };
    const manifests = try scratch.alloc(Manifest, scopes.len);

    for (resolved.packages, manifests) |package, *manifest| manifest.* = package.manifest;

    return .{ .scopes = scopes, .manifests = manifests, .entry = real, .owner = owner };
}
