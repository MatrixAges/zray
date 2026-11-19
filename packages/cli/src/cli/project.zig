const std = @import("std");
const Inputs = @import("watch/inputs.zig");
const compiler = @import("compiler");
const zx = @import("zx");
const rules = @import("cli_source");
const model = @import("../package/manifest/model.zig");
const manifest = @import("../package/manifest.zig");
pub const NativeModule = model.NativeModule;
pub const NativeInterface = model.NativeInterface;
pub const Config = model.Manifest;
pub const NativeSettings = @import("project/scopes.zig").NativeSettings;
pub const Loaded = struct { project: compiler.project.Options, config: Config = .{ .name = "", .version = "" }, native_settings: []const NativeSettings = &.{}, diagnostic: ?[]const u8 = null };
pub const NativeScope = struct { root: []const u8, paths: []const []const u8 };

pub fn nativeScope(loaded: Loaded, module: NativeModule) NativeScope {
    const settings = loaded.native_settings;
    const names = zx.memory.borrowTextColumn("name", settings);
    const roots = zx.memory.borrowTextColumn("root", settings);
    const includes = zx.memory.borrowReadColumn([]const []const u8, "include_paths", settings);

    const input: std.meta.Child(rules.native_include_scope.Input) = .{
        .count = settings.len,
        .names = @ptrCast(&names),
        .roots = @ptrCast(&roots),
        .includes = @ptrCast(&includes),
        .name = module.name,
        .default_root = loaded.project.root_dir,
        .default_paths = loaded.config.include_paths,
        .explicit = module.include_paths,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const scope = zx.columns.invoke(rules.native_include_scope.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .root = scope.root, .paths = scope.paths };
}

pub fn nativeIndex(comptime field: []const u8, rows: anytype, name: []const u8, last: bool) ?usize {
    const names = zx.memory.borrowTextColumn(field, rows);

    const input: std.meta.Child(rules.native_module_lookup.Input) = .{
        .count = rows.len,
        .names = @ptrCast(&names),
        .name = name,
        .last = last,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const index = zx.columns.invoke(rules.native_module_lookup.executeValue, empty.allocator(), &input) catch unreachable;

    return if (index) |value| @intCast(value) else null;
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8) !Loaded {
    return loadWithInputs(io, allocator, entry, config_path, null);
}

pub fn loadWithInputs(io: std.Io, allocator: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8, inputs: ?*Inputs) !Loaded {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const source_path = try std.fs.path.resolve(allocator, &.{ cwd, entry });
    const packages = try @import("../package/project.zig").loadWithInputs(io, allocator, source_path, config_path, inputs);
    var loaded = Loaded{ .project = .{ .entry = packages.entry orelse source_path, .root_dir = cwd, .package_scopes = packages.scopes }, .diagnostic = packages.diagnostic };

    if (loaded.diagnostic != null) return loaded;

    const path = packages.manifest_path orelse return loaded;

    if (inputs) |observed| try observed.add(io, path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));

    if (inputs) |observed| try observed.record(io, path, source);

    const parsed = try manifest.parse(allocator, source);

    const config = switch (parsed.value) {
        .data => |data| data,
        .diagnostic => |issue| {
            loaded.diagnostic = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: manifest: {s}", .{ path, issue.line, issue.column, issue.message });

            return loaded;
        },
    };

    const root_dir = std.fs.path.dirname(path).?;
    const resolved = try @import("project/scopes.zig").load(io, allocator, packages.scopes, root_dir, config, inputs);

    return .{
        .project = .{
            .entry = loaded.project.entry,
            .root_dir = root_dir,
            .package_scopes = resolved.scopes,
            .externals = resolved.config.externals,
            .native_interfaces = resolved.interfaces,
        },
        .config = resolved.config,
        .native_settings = resolved.settings,
    };
}
