const std = @import("std");

pub fn create(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const files = b.addWriteFiles();
    const sources = b.path("src/arguments");

    _ = files.addCopyDirectory(sources, "arguments", .{ .include_extensions = &.{ ".rx", ".zx" } });

    for ([_][]const u8{ "const.zx", "ascii/const.zx" }) |file| {
        _ = files.addCopyFile(core.path(b.fmt("src/{s}", .{file})), b.fmt("core/{s}", .{file}));
    }

    const run = std.Build.Step.Run.create(b, "generate CLI argument parsers");

    run.addFileArg2(compiler.namedLazyPath("source_generator"), .{ .make_absolute = true });
    run.setCwd(files.getDirectory());
    run.setEnvironmentVariable("ZXC_RESIDENT_GENERATOR", "0");
    run.addArg("--manifest");
    run.addFileArg2(files.addCopyFile(b.path("build/arguments.json"), "manifest.json"), .{ .make_absolute = true });

    const generated = run.addOutputDirectoryArg("arguments");

    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "cli-argument-functions"), .{ .make_absolute = true });

    return b.createModule(.{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "zxc_standard", .module = compiler.module("generated_standard") },
        },
    });
}
