const std = @import("std");
const project_config = @import("../project.zig");
const artifacts = @import("../artifacts.zig");
const native_sources = @import("../native_sources.zig");
const Inputs = @import("watch_inputs").Inputs;
pub const Dependency = struct { name: []const u8, header: ?[]const u8, c_imports: bool = false, dynamic_resources: bool = false, include_relocations: []const native_sources.Include = &.{} };

pub const Result = struct {
    native_modules: []const project_config.NativeModule,
    library_paths: []const []const u8,
    bundled_files: []const native_sources.File,
    dependencies: []const Dependency,
    external_includes: []const []const u8,
};

pub fn write(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, loaded: project_config.Loaded, inputs: ?*Inputs) !Result {
    const native_modules = try allocator.dupe(project_config.NativeModule, loaded.config.native_modules);
    const library_paths = try absolutePaths(allocator, loaded.project.root_dir, loaded.config.library_paths);
    var bundled_files: std.ArrayList(native_sources.File) = .empty;
    var dependencies: std.ArrayList(Dependency) = .empty;
    var external_includes: std.ArrayList([]const u8) = .empty;

    for (native_modules) |*native| {
        var dependency = Dependency{ .name = native.name, .header = native.header, .c_imports = native.header != null };
        const scope = project_config.nativeScope(loaded, native.*);

        native.include_paths = try absolutePaths(allocator, scope.root, scope.paths);

        if (native.path != null or native.bundle_files.len != 0) {
            const bundled = try native_sources.writeWithInputs(io, allocator, directory, scope.root, native.*, inputs);

            native.path = bundled.entry;
            native.include_paths = bundled.include_paths;
            dependency.c_imports = bundled.c_imports;
            dependency.dynamic_resources = bundled.dynamic_resources;
            dependency.include_relocations = bundled.include_relocations;

            try bundled_files.appendSlice(allocator, bundled.files);

            if (native.header != null) {
                const paths = try allocator.alloc([]const u8, bundled.files.len);

                for (bundled.files, paths) |file, *path| path.* = file.path;

                native.bundle_files = paths;
            }
        }

        for (native.include_paths.?) |path| {
            if (std.fs.path.isAbsolute(path)) try external_includes.append(allocator, path);
        }

        try dependencies.append(allocator, dependency);

        if (native.header) |header| {
            const path = try std.fmt.allocPrint(allocator, "{s}/native/{s}.zig", .{ directory, native.name });
            const header_path = try std.fmt.allocPrint(allocator, "{s}/native/{s}.h", .{ directory, native.name });
            const include = try std.json.Stringify.valueAlloc(allocator, header, .{});

            try artifacts.write(io, header_path, try std.fmt.allocPrint(allocator, "#include {s}\n", .{include}));

            const adapter = try @import("compiler").zig.host.cAdapter(allocator);

            defer allocator.free(adapter);

            try artifacts.write(io, path, adapter);
        }
    }

    return .{
        .native_modules = native_modules,
        .library_paths = library_paths,
        .bundled_files = bundled_files.items,
        .dependencies = dependencies.items,
        .external_includes = external_includes.items,
    };
}

fn absolutePaths(allocator: std.mem.Allocator, root: []const u8, paths: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, paths.len);

    for (paths, result) |path, *absolute| absolute.* = try std.fs.path.resolve(allocator, &.{ root, path });

    return result;
}
