const std = @import("std");

pub fn create(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/arguments"), "arguments", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/archive"), "archive", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/workspace"), "workspace", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/project"), "package_project", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/manifest"), "package_manifest", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/native_sources"), "native_sources", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/library"), "library", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/sources"), "sources", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/build/workspace"), "workspace_files", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/publication"), "publication", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/build/dependencies"), "backend_dependencies", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/build/command"), "command", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/watch/diagnostics"), "watch_diagnostics", .{ .include_extensions = &.{".zx"} });
    _ = files.addCopyDirectory(b.path("src/cli/standard"), "standard", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/project/scopes"), "scopes", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyFile(compiler.namedLazyPath("memory_interface"), "memory/index.d.zx");
    _ = files.addCopyFile(compiler.namedLazyPath("memory_columns_interface"), "memory/columns.d.zx");

    for ([_][]const u8{ "const.zx", "ascii/const.zx" }) |file| {
        _ = files.addCopyFile(core.path(b.fmt("src/{s}", .{file})), b.fmt("core/{s}", .{file}));
    }

    const generated = generate(b, compiler, files, "build/source.json", "cli");

    const manifest_output = b.addModule("manifest_output", .{
        .root_source_file = b.path("src/package/manifest/write/output.zig"),
        .target = target,
        .optimize = optimize,
    });

    const artifact_io = b.addModule("artifact_io", .{
        .root_source_file = b.path("src/cli/build/workspace/io.zig"),
        .target = target,
        .optimize = optimize,
    });

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
            .{ .name = "manifest_output", .module = manifest_output },
            .{ .name = "artifact_io", .module = artifact_io },
        },
    });
}

pub fn packages(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, effects: *std.Build.Module) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/package/install"), "package_install", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/graph"), "package_graph", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/packages.json", "packages");

    return b.createModule(.{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "installation_host", .module = effects },
            .{ .name = "package_graph_host", .module = effects },
        },
    });
}

pub fn store(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, pkgs: *std.Build.Module, cli_source: *std.Build.Module) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/package/store"), "store", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/archive/extract"), "extract", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/store.json", "store");

    const host = b.addModule("package_store", .{
        .root_source_file = b.path("src/package/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pkgs", .module = pkgs },
            .{ .name = "cli_source", .module = cli_source },
        },
    });

    const effects = b.createModule(.{
        .root_source_file = b.path("src/package/store/bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "package_store", .module = host }},
    });

    host.addAnonymousImport("package_cache", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "package_cache_host", .module = effects },
            .{ .name = "package_extract_host", .module = effects },
            .{ .name = "package_receipt_host", .module = effects },
            .{ .name = "package_download_host", .module = effects },
        },
    });

    return host;
}

pub fn toolchain(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host: *std.Build.Module) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/cli/toolchain"), "toolchain", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/toolchain.json", "toolchain");

    const effects = b.createModule(.{
        .root_source_file = b.path("src/cli/toolchain/bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cli_host", .module = host }},
    });

    const source = b.createModule(.{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "toolchain_environment", .module = effects },
            .{ .name = "toolchain_host", .module = effects },
        },
    });

    const cache = b.addModule("toolchain_cache", .{
        .root_source_file = b.path("src/cli/toolchain/cache.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cli_toolchain", .module = source }},
    });

    host.addImport("toolchain_cache", cache);

    return source;
}

pub fn watch(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host: *std.Build.Module) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/cli/watch/driver"), "driver", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/watch.json", "watch");
    const abi = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") });

    const effects = b.createModule(.{
        .root_source_file = b.path("src/cli/watch/driver/bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cli_host", .module = host }},
    });

    host.addImport("cli_watch_abi", abi);

    return b.createModule(.{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "watch_host", .module = effects },
        },
    });
}

pub fn observations(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cli_source: *std.Build.Module) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/cli/watch/observation"), "observation", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/observation.json", "observation");
    const abi = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") });

    const observations_module = b.addModule("watch_inputs", .{
        .root_source_file = b.path("src/watch_inputs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compiler", .module = compiler.module("compiler") },
            .{ .name = "cli_source", .module = cli_source },
            .{ .name = "watch_observation_abi", .module = abi },
        },
    });

    const effects = b.createModule(.{
        .root_source_file = b.path("src/cli/watch/observation/bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "watch_inputs", .module = observations_module }},
    });

    observations_module.addAnonymousImport("watch_observation", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = compiler.module("generated_standard") },
            .{ .name = "snapshot_host", .module = effects },
        },
    });

    return observations_module;
}

pub fn backend(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/cli/backend/source"), "source", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/backend.json", "backend");
    const abi = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") });

    const protocol = b.addModule("backend_protocol", .{
        .root_source_file = b.path("src/cli/backend/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "backend_abi", .module = abi }},
    });

    const effects = b.createModule(.{
        .root_source_file = b.path("src/cli/backend/bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "backend_protocol", .module = protocol }},
    });

    protocol.addAnonymousImport("backend_source", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = compiler.module("generated_standard") },
            .{ .name = "backend_frames", .module = effects },
            .{ .name = "backend_diagnostics", .module = effects },
        },
    });

    return protocol;
}

fn generate(b: *std.Build, compiler: *std.Build.Dependency, files: *std.Build.Step.WriteFile, manifest: []const u8, output: []const u8) std.Build.LazyPath {
    const run = std.Build.Step.Run.create(b, "generate CLI source modules");

    run.addFileArg2(compiler.namedLazyPath("source_generator"), .{ .make_absolute = true });
    run.setCwd(files.getDirectory());
    run.setEnvironmentVariable("ZXC_RESIDENT_GENERATOR", "0");
    run.addArg("--manifest");
    run.addFileArg2(files.addCopyFile(b.path(manifest), "manifest.json"), .{ .make_absolute = true });

    const generated = run.addOutputDirectoryArg(output);

    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "cli-functions"), .{ .make_absolute = true });

    return generated;
}
