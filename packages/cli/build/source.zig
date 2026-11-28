const std = @import("std");

pub fn create(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("src/arguments"), "arguments", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/archive"), "archive", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/workspace"), "workspace", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/project"), "package_project", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/manifest"), "package_manifest", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/install"), "package_install", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/graph"), "package_graph", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/store"), "store", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/package/archive/extract"), "extract", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/native_sources"), "native_sources", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/library"), "library", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/sources"), "sources", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/toolchain"), "toolchain", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/watch/driver"), "driver", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/watch/observation"), "observation", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/backend/source"), "backend_source", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/collection"), "rx_collection", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/preparation"), "rx_preparation", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/checking"), "rx_checking", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/rx/execution"), "rx_execution", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/compilation"), "compilation", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/lint"), "lint_workflow", .{ .include_extensions = &.{ ".rx", ".zx" } });
    _ = files.addCopyDirectory(b.path("src/cli/configuration"), "configuration_workflow", .{ .include_extensions = &.{ ".rx", ".zx" } });
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
    _ = files.addCopyFile(core.path("interfaces/memory/maps.d.zx"), "memory/maps.d.zx");

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

    const artifact_io = b.addModule("artifact_io", .{
        .root_source_file = b.path("src/cli/build/workspace/io.zig"),
        .target = target,
        .optimize = optimize,
    });

    const maps = b.addModule("memory_maps", .{
        .root_source_file = core.path("src/memory/maps.zig"),
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
            .{ .name = "memory/maps", .module = maps },
            .{ .name = "lexical_path", .module = compiler.module("generated_standard") },
            .{ .name = "artifact_io", .module = artifact_io },
        },
    });
}

pub fn store(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, pkgs: *std.Build.Module, cli_source: *std.Build.Module) *std.Build.Module {
    const module = b.addModule("package_store", .{
        .root_source_file = b.path("src/package/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pkgs", .module = pkgs },
            .{ .name = "zx", .module = core },
            .{ .name = "cli_source", .module = cli_source },
            .{ .name = "cli_abi", .module = cli_source.import_table.get("zxc_abi").? },
        },
    });

    for ([_][]const u8{
        "package_cache_host",
        "package_extract_host",
        "package_receipt_host",
        "package_download_host",
    }) |name| cli_source.addImport(name, module);

    return module;
}

pub fn toolchain(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host: *std.Build.Module, cli_source: *std.Build.Module) void {
    const effects = b.createModule(.{
        .root_source_file = b.path("src/cli/toolchain/bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cli_host", .module = host }},
    });

    cli_source.addImport("toolchain_host", effects);

    const cache = b.addModule("toolchain_cache", .{
        .root_source_file = b.path("src/cli/toolchain/cache.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cli_source", .module = cli_source }},
    });

    host.addImport("toolchain_cache", cache);
}

pub fn observations(b: *std.Build, compiler: *std.Build.Dependency, core: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cli_source: *std.Build.Module) *std.Build.Module {
    const module = b.addModule("watch_inputs", .{
        .root_source_file = b.path("src/watch_inputs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compiler", .module = compiler.module("compiler") },
            .{ .name = "artifact_io", .module = b.modules.get("artifact_io").? },
            .{ .name = "cli_abi", .module = cli_source.import_table.get("zxc_abi").? },
            .{ .name = "cli_source", .module = cli_source },
            .{ .name = "zx", .module = core },
        },
    });

    cli_source.addImport("snapshot_host", module);

    return module;
}

pub fn backend(b: *std.Build, core: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cli_source: *std.Build.Module) *std.Build.Module {
    const protocol = b.addModule("backend_protocol", .{
        .root_source_file = b.path("src/cli/backend/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli_source", .module = cli_source },
            .{ .name = "zx", .module = core },
            .{ .name = "memory/maps", .module = b.modules.get("memory_maps").? },
        },
    });

    cli_source.addImport("backend_process", protocol);

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
