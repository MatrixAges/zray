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
    _ = files.addCopyDirectory(b.path("src/cli/rx/collection"), "rx_collection", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/preparation"), "rx_preparation", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/checking"), "rx_checking", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/execution"), "rx_execution", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/compilation"), "compilation", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/lint"), "lint_workflow", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/configuration"), "configuration_workflow", .{ .include_extensions = &.{".rx"} });
    _ = files.addCopyDirectory(b.path("src/cli/build/workspace"), "workspace_files", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/publication"), "publication", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/build/dependencies"), "backend_dependencies", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/build/command"), "command", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/watch/diagnostics"), "watch_diagnostics", .{ .include_extensions = &.{".zx"} });
    _ = files.addCopyDirectory(b.path("src/cli/standard"), "standard", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/project/scopes"), "scopes", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/abi"), "abi", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyFile(compiler.namedLazyPath("abi_alias_type"), "abi/alias.zx");
    _ = files.addCopyDirectory(core.path("src/row_buffer"), "core/row_buffer", .{ .include_extensions = &.{".zx"} });
    _ = files.addCopyDirectory(core.path("src/native_module_table"), "core/native_module_table", .{ .include_extensions = &.{".zx"} });
    _ = files.addCopyDirectory(compiler.path("src/zx/modules/compiled/identity/aliases"), "compiler_rules/compiled/identity/aliases", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyFile(compiler.namedLazyPath("memory_interface"), "memory/index.d.zx");
    _ = files.addCopyFile(compiler.namedLazyPath("memory_columns_interface"), "memory/columns.d.zx");
    _ = files.addCopyFile(compiler.path("src/zx/modules/path/lexical.d.zx"), "memory/lexical.d.zx");

    for ([_][]const u8{ "const.zx", "ascii/const.zx", "bytes/index/slot.zx", "bytes/index/borrowed/wide_slot.zx" }) |file| {
        _ = files.addCopyFile(core.path(b.fmt("src/{s}", .{file})), b.fmt("core/{s}", .{file}));
    }

    for ([_][]const u8{
        "compiled/const.zx",
        "compiled/identity/declaration.zx",
        "compiled/identity/native_name.zx",
        "compiled/identity/own_declaration.zx",
        "compiled/identity/scope.zx",
        "compiled/identity/standard.zx",
        "compiled/loading/selection/locate.zx",
        "path/const.zx",
        "project/target/select.zx",
        "specifier/check.zx",
        "specifier/model.zx",
    }) |file| {
        _ = files.addCopyFile(compiler.path(b.fmt("src/zx/modules/{s}", .{file})), b.fmt("compiler_rules/{s}", .{file}));
    }

    for ([_][]const u8{ "contains.zx", "model.zx", "scoped.zx" }) |file| {
        _ = files.addCopyFile(compiler.path(b.fmt("src/backends/zig/source_abi/{s}", .{file})), b.fmt("compiler_rules/source_abi/{s}", .{file}));
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
            .{ .name = "lexical_path", .module = compiler.module("generated_standard") },
            .{ .name = "manifest_output", .module = manifest_output },
            .{ .name = "artifact_io", .module = artifact_io },
        },
    });
}

pub fn packages(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host: *std.Build.Module) *std.Build.Module {
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
            .{ .name = "installation_host", .module = host },
            .{ .name = "package_graph_host", .module = host },
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
            .{ .name = "zx", .module = b.dependency("core", .{ .target = target, .optimize = optimize }).module("core") },
            .{ .name = "cli_source", .module = cli_source },
        },
    });

    host.addAnonymousImport("package_cache", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") }) },
            .{ .name = "package_cache_host", .module = host },
            .{ .name = "package_extract_host", .module = host },
            .{ .name = "package_receipt_host", .module = host },
            .{ .name = "package_download_host", .module = host },
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

pub fn observations(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/cli/watch/observation"), "observation", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyFile(b.path("src/package/workspace/ignored.zx"), "workspace/ignored.zx");
    _ = files.addCopyFile(b.path("src/package/workspace/const.zx"), "workspace/const.zx");

    const generated = generate(b, compiler, files, "build/observation.json", "observation");
    const abi = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") });

    const observations_module = b.addModule("watch_inputs", .{
        .root_source_file = b.path("src/watch_inputs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compiler", .module = compiler.module("compiler") },
            .{ .name = "artifact_io", .module = b.modules.get("artifact_io").? },
            .{ .name = "watch_observation_abi", .module = abi },
            .{ .name = "zx", .module = b.dependency("core", .{ .target = target, .optimize = optimize }).module("core") },
        },
    });

    observations_module.addAnonymousImport("watch_observation", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = compiler.module("generated_standard") },
            .{ .name = "snapshot_host", .module = observations_module },
        },
    });

    return observations_module;
}

pub fn backend(b: *std.Build, compiler: *std.Build.Dependency, core: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/cli/backend/source"), "source", .{ .include_extensions = &.{ ".rx", ".zx" } });

    const generated = generate(b, compiler, files, "build/backend.json", "backend");
    const abi = b.createModule(.{ .root_source_file = generated.path(b, "types.zig") });

    const protocol = b.addModule("backend_protocol", .{
        .root_source_file = b.path("src/cli/backend/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend_abi", .module = abi },
            .{ .name = "zx", .module = core },
        },
    });

    protocol.addAnonymousImport("backend_source", .{
        .root_source_file = generated.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = compiler.module("generated_standard") },
            .{ .name = "backend_frames", .module = protocol },
            .{ .name = "backend_diagnostics", .module = protocol },
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
