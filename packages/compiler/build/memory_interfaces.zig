const std = @import("std");
const LazyPath = std.Build.LazyPath;
pub const Declarations = struct { directory: LazyPath, prefix: []const u8 };

const Result = struct {
    index: LazyPath,
    columns: LazyPath,
    index_path: []const u8,
    columns_path: []const u8,
    manifests: LazyPath,
};

pub fn create(b: *std.Build, core: *std.Build.Dependency, manifests: LazyPath, source_root: []const u8, execution: []const Declarations) Result {
    const files = b.addWriteFiles();
    const directory = "interfaces/memory";
    const index = files.add("index.d.zx", join(b, core.builder, directory, &.{ "types.d.zx", "views.d.zx", "row_reads.d.zx", "buffer_values.d.zx", "scalar_buffers.d.zx", "atomic_rows.d.zx", "stream.d.zx", "column_writes.d.zx", "text_storage.d.zx" }));
    const columns = files.add("columns.d.zx", join(b, core.builder, directory, &.{ "function_descriptors.d.zx", "column_sets.d.zx", "column_set_operations.d.zx", "row_storage.d.zx", "column_values.d.zx", "reference_views.d.zx" }));
    const prefix = b.fmt("{s}/memory/", .{source_root});

    const tool = b.addExecutable(.{
        .name = "bind-bootstrap-interfaces",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/bind_interfaces.zig"),
            .target = b.graph.host,
            .optimize = .small,
        }),
    });

    const run = b.addRunArtifact(tool);

    run.addDirectoryArg2(manifests, .{});
    run.addDirectoryArg2(files.getDirectory(), .{ .make_absolute = true });
    run.addArg(prefix);

    for (execution) |binding| {
        run.addDirectoryArg2(binding.directory, .{ .make_absolute = true });
        run.addArg(binding.prefix);
    }

    return .{
        .index = index,
        .columns = columns,
        .index_path = b.fmt("{s}index.d.zx", .{prefix}),
        .columns_path = b.fmt("{s}columns.d.zx", .{prefix}),
        .manifests = run.addOutputDirectoryArg("manifests"),
    };
}

pub fn join(b: *std.Build, package: *std.Build, directory: []const u8, comptime names: []const []const u8) []const u8 {
    var parts: [names.len][]const u8 = undefined;

    for (names, &parts) |name, *part| part.* = read(b, package, directory, name);

    return std.mem.join(b.allocator, "\n", &parts) catch @panic("out of memory");
}

fn read(b: *std.Build, package: *std.Build, directory: []const u8, name: []const u8) []const u8 {
    const relative = b.fmt("{s}/{s}", .{ directory, name });

    b.dependOnFileContents(package.path(relative));

    const path = package.root.joinString(b.allocator, relative) catch @panic("out of memory");

    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch @panic("unable to read internal declarations");
}
