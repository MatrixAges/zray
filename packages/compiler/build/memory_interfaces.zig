const std = @import("std");
const LazyPath = std.Build.LazyPath;

const Result = struct {
    index: LazyPath,
    columns: LazyPath,
    index_path: []const u8,
    columns_path: []const u8,
    manifests: LazyPath,
};

pub fn create(b: *std.Build, core: *std.Build.Dependency, manifests: LazyPath, source_root: []const u8) Result {
    const files = b.addWriteFiles();
    const index = files.add("index.d.zx", join(b, core, "views.d.zx", "buffer_values.d.zx"));
    const columns = files.add("columns.d.zx", join(b, core, "column_sets.d.zx", "column_values.d.zx"));
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

    return .{
        .index = index,
        .columns = columns,
        .index_path = b.fmt("{s}index.d.zx", .{prefix}),
        .columns_path = b.fmt("{s}columns.d.zx", .{prefix}),
        .manifests = run.addOutputDirectoryArg("manifests"),
    };
}

fn join(b: *std.Build, core: *std.Build.Dependency, first: []const u8, second: []const u8) []const u8 {
    return std.mem.concat(b.allocator, u8, &.{ read(b, core, first), "\n", read(b, core, second) }) catch @panic("out of memory");
}

fn read(b: *std.Build, core: *std.Build.Dependency, name: []const u8) []const u8 {
    const relative = b.fmt("interfaces/memory/{s}", .{name});

    b.dependOnFileContents(core.path(relative));

    const path = core.builder.root.joinString(b.allocator, relative) catch @panic("out of memory");

    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch @panic("unable to read internal memory declarations");
}
