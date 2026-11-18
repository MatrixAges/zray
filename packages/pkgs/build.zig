const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stage0 = b.option([]const u8, "stage0", "Pinned bootstrap generator executable") orelse "";
    const partitions = b.option(u32, "generated-partitions", "Generated compiler partitions") orelse 0;
    const share_standard = b.option(bool, "share-compiler-standard", "Link with the compiler standard module when both are in the same executable") orelse false;
    const compiler = b.dependency("compiler", .{ .target = target, .optimize = optimize, .stage0 = stage0, .@"generated-partitions" = partitions });
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const files = b.addWriteFiles();

    for ([_][]const u8{ "version", "workspace", "metadata" }) |dir| {
        _ = files.addCopyDirectory(b.path(b.fmt("src/{s}", .{dir})), dir, .{ .include_extensions = &.{ ".zx", ".rx" } });
    }

    for ([_][]const u8{ "const.zx", "ascii/const.zx" }) |file| {
        _ = files.addCopyFile(core.path(b.fmt("src/{s}", .{file})), b.fmt("core/{s}", .{file}));
    }

    const run = std.Build.Step.Run.create(b, "generate package dependency rules");

    run.addFileArg2(compiler.namedLazyPath("source_generator"), .{ .make_absolute = true });
    run.setCwd(files.getDirectory());
    run.setEnvironmentVariable("ZXC_RESIDENT_GENERATOR", "0");
    run.addArg("--manifest");
    run.addFileArg2(files.addCopyFile(b.path("build/source.json"), "manifest.json"), .{ .make_absolute = true });

    const generated = run.addOutputDirectoryArg("pkgs");

    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "pkgs-functions"), .{ .make_absolute = true });

    const rules = b.createModule(.{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "zxc_standard", .module = compiler.module(if (share_standard) "generated_standard" else "standard") },
        },
    });

    const module = b.addModule("pkgs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pkgs_source", .module = rules }},
    });

    b.installArtifact(b.addLibrary(.{ .name = "zxc_pkgs", .root_module = module }));
    b.addNamedLazyPath("index", b.path("index.json"));
}
