const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const compiler = @import("compiler");
const model = @import("../package/manifest/model.zig");
pub const NativeModule = model.NativeModule;
pub const NativeInterface = model.NativeInterface;
pub const Config = model.Manifest;
pub const NativeSettings = @import("project/scopes.zig").NativeSettings;
pub const Loaded = struct { project: compiler.project.Options, config: Config = .{ .name = "", .version = "" }, native_settings: []const NativeSettings = &.{}, diagnostic: ?[]const u8 = null };

pub fn load(io: std.Io, allocator: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8) !Loaded {
    return loadWithInputs(io, allocator, entry, config_path, null);
}

pub fn loadWithInputs(io: std.Io, allocator: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8, inputs: ?*Inputs) !Loaded {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer scratch.deinit();

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const source_path = try std.fs.path.resolve(allocator, &.{ cwd, entry });
    const packages = try @import("../package/project.zig").loadWithInputs(io, allocator, scratch.allocator(), source_path, config_path, inputs);
    const loaded = Loaded{ .project = .{ .entry = packages.entry orelse source_path, .root_dir = cwd, .package_scopes = packages.scopes }, .diagnostic = packages.diagnostic };

    if (loaded.diagnostic != null) return loaded;

    const owner = packages.owner orelse return loaded;
    const root_dir = packages.scopes[owner].root;
    const resolved = try @import("project/scopes.zig").load(io, allocator, packages.scopes, packages.manifests, owner, inputs);

    return .{
        .project = .{
            .entry = loaded.project.entry,
            .root_dir = root_dir,
            .package_scopes = packages.scopes,
            .externals = resolved.config.externals,
            .native_interfaces = resolved.interfaces,
        },
        .config = resolved.config,
        .native_settings = resolved.settings,
    };
}
