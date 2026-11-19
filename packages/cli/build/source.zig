const std = @import("std");

pub fn create(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/arguments"), "arguments", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/archive"), "archive", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/workspace"), "workspace", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/project"), "package_project", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/native_sources"), "native_sources", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/library"), "library", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/build/command"), "command", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/standard"), "standard", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/project/scopes"), "scopes", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyFile(compiler.namedLazyPath("memory_interface"), "memory/index.d.zx");
    _ = files.addCopyFile(compiler.namedLazyPath("memory_columns_interface"), "memory/columns.d.zx");

    for ([_][]const u8{ "const.zx", "ascii/const.zx" }) |file| {
        _ = files.addCopyFile(core.path(b.fmt("src/{s}", .{file})), b.fmt("core/{s}", .{file}));
    }

    const run = std.Build.Step.Run.create(b, "generate CLI source modules");

    run.addFileArg2(compiler.namedLazyPath("source_generator"), .{ .make_absolute = true });
    run.setCwd(files.getDirectory());
    run.setEnvironmentVariable("ZXC_RESIDENT_GENERATOR", "0");
    run.addArg("--manifest");
    run.addFileArg2(files.addCopyFile(b.path("build/source.json"), "manifest.json"), .{ .make_absolute = true });

    const generated = run.addOutputDirectoryArg("cli");

    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "cli-functions"), .{ .make_absolute = true });

    return b.addModule("cli_source", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "zxc_standard", .module = compiler.module("generated_standard") },
            .{ .name = "zxc_string", .module = compiler.module("generated_string") },
            .{ .name = "memory", .module = core.module("memory") },
            .{ .name = "memory/columns", .module = core.module("memory") },
        },
    });
}
