const std = @import("std");
const entries = @import("entries.zig");
const memory_columns = "memory/columns";
const lexical_path = "lexical_path";
const ownership_interface = "analysis/uniqueness/program/driver/native.d.zx";
const lowering_declarations = "analysis/expressions/evaluate/";
const partition_interface = "build/partition/driver.d.zx";

pub const Sources = struct { standard_abi: std.Build.LazyPath, main: std.Build.LazyPath, checks: std.Build.LazyPath, collections: std.Build.LazyPath, growth: std.Build.LazyPath, execution: std.Build.LazyPath, host: std.Build.LazyPath };

pub fn generate(b: *std.Build, optimize: std.builtin.OptimizeMode, stage0: []const u8, partitions: u32, executable: *std.Build.Step.Compile) Sources {
    const target = b.graph.host;
    // Debug iteration reruns the generator on every source edit, so it runs unchecked there: ReleaseFast cuts a
    // cached run by about a third and compiles as quickly as ReleaseSafe. Other modes keep the requested checks.
    const generator_optimize: std.builtin.OptimizeMode = if (optimize == .debug) .fast else optimize;
    const core_dependency = b.dependency("core", .{ .target = target, .optimize = generator_optimize });
    const lint_dependency = b.dependency("lint", .{ .target = target, .optimize = generator_optimize, .seed = true });
    const standard = generatorRun(b, executable, stage0);

    standard.addArg("--standard-abi");

    const standard_abi = standard.addOutputFileArg("standard_abi.zig");
    const genz_dependency = b.dependency("genz", .{ .target = target, .optimize = generator_optimize });
    const roots = [_]std.Build.LazyPath{ b.path("src"), lint_dependency.path("src"), core_dependency.path("src"), genz_dependency.path("src") };

    const directories = [_][]const u8{
        b.root.joinString(b.allocator, "src") catch @panic("out of memory"),
        lint_dependency.builder.root.joinString(b.allocator, "src") catch @panic("out of memory"),
        core_dependency.builder.root.joinString(b.allocator, "src") catch @panic("out of memory"),
        genz_dependency.builder.root.joinString(b.allocator, "src") catch @panic("out of memory"),
    };

    var sources: Sources = undefined;
    sources.standard_abi = standard_abi;

    const manifests = b.addWriteFiles();
    const manifest = @import("generation_manifest.zig");
    const internal = @import("memory_interfaces.zig");
    const execution_interfaces_dir = b.addWriteFiles();
    const lowering = execution_interfaces_dir.add("lowering.d.zx", internal.join(b, genz_dependency, "src/" ++ lowering_declarations, &.{ "frames.d.zx", "native.d.zx", "read.d.zx", "scope.d.zx", "aggregate.d.zx", "match.d.zx", "call.d.zx", "consumer.d.zx", "iteration.d.zx", "function.d.zx", "module.d.zx", "resources.d.zx", "publication.d.zx" }));
    const lowering_prefix = b.fmt("{s}/{s}", .{ directories[3], lowering_declarations });

    const declarations = internal.create(b, core_dependency, manifests.getDirectory(), directories[2], .{
        .directory = execution_interfaces_dir.getDirectory(),
        .prefix = lowering_prefix,
    });

    b.addNamedLazyPath("memory_interface", declarations.index);
    b.addNamedLazyPath("memory_columns_interface", declarations.columns);

    const manifest_roots = [_]manifest.Root{
        .{ .path = directories[0] },
        .{ .path = directories[1], .prefix = "lint/" },
        .{ .path = directories[2], .prefix = "core/" },
        .{ .path = directories[3], .prefix = "genz/" },
    };

    var tracked: [roots.len][]const SourceInput = undefined;

    for (roots, directories, &tracked) |root, directory, *inputs| {
        inputs.* = sourceInputs(b, root, directory) catch @panic("unable to track RX and ZX bootstrap sources");
    }

    const interfaces = [_]manifest.Interface{
        .{
            .specifier = "zig:string",
            .path = b.dependency("zxc_std", .{}).builder.root.joinString(b.allocator, "interfaces/string.d.zx") catch @panic("out of memory"),
            .module = "zxc_string",
        },
        .{ .path = declarations.index_path, .module = "memory" },
        .{ .path = declarations.columns_path, .module = memory_columns },
    };

    const hardware_graph_interface: manifest.Interface = .{
        .path = b.fmt("{s}/backends/hardware/graph/view.d.zx", .{directories[0]}),
        .module = "hardware_graph_host",
    };

    const main_interfaces = interfaces ++ [_]manifest.Interface{
        .{ .path = b.fmt("{s}/zx/modules/path/lexical.d.zx", .{directories[0]}), .module = lexical_path },
        hardware_graph_interface,
    };

    const execution_interfaces = interfaces ++ [_]manifest.Interface{
        .{ .path = b.fmt("{s}/{s}", .{ directories[3], ownership_interface }), .module = "ownership_host" },
        .{ .path = b.fmt("{s}lowering.d.zx", .{lowering_prefix}), .module = "lowering_host" },
        .{ .path = b.fmt("{s}/zx/modules/project/execution/host.d.zx", .{directories[0]}), .module = "project_host" },
        .{ .path = b.fmt("{s}/rx/analysis/project/workflow/host.d.zx", .{directories[0]}), .module = "rx_project_host" },
        .{ .path = b.fmt("{s}/backends/zig/output_host.d.zx", .{directories[0]}), .module = "output_host" },
        .{ .path = b.fmt("{s}/verification/host.d.zx", .{directories[0]}), .module = "verification_host" },
        .{ .path = b.fmt("{s}/verification/execution/program/host.d.zx", .{directories[0]}), .module = "verification_program_host" },
        .{ .path = b.fmt("{s}/verification/publication/host.d.zx", .{directories[0]}), .module = "verification_publication_host" },
        .{ .path = b.fmt("{s}/backends/hardware/construction/workflow/host.d.zx", .{directories[0]}), .module = "hardware_build_host" },
        hardware_graph_interface,
        .{ .path = b.fmt("{s}/backends/verilog/workflow/writer.d.zx", .{directories[0]}), .module = "verilog_host" },
    };

    const host_interfaces = interfaces ++ [_]manifest.Interface{
        .{ .path = b.root.joinString(b.allocator, partition_interface) catch @panic("out of memory"), .module = "partition_host" },
    };

    // Each entry set runs as its own step, so builds that never import the checks do not generate them.
    for ([_]entries.Set{ .main, .checks, .constant_seed, .snapshot_seed, .partition_seed, .collections, .growth, .execution, .host }) |set| {
        const run = generatorRun(b, executable, stage0);

        const project = manifest.Project{
            .roots = switch (set) {
                .collections => &.{ manifest_roots[2], .{
                    .path = b.fmt("{s}/analysis/state/locals", .{directories[3]}),
                    .prefix = "genz/analysis/state/locals/",
                }, .{
                    .path = b.fmt("{s}/analysis/state/queries", .{directories[3]}),
                    .prefix = "genz/analysis/state/queries/",
                }, .{
                    .path = b.fmt("{s}/analysis/members", .{directories[3]}),
                    .prefix = "genz/analysis/members/",
                }, .{
                    .path = b.fmt("{s}/analysis/iteration/transfer/history", .{directories[3]}),
                    .prefix = "genz/analysis/iteration/transfer/history/",
                } },
                .execution => &.{ manifest_roots[0], manifest_roots[2], manifest_roots[3] },
                .growth, .host => manifest_roots[2..],
                else => &manifest_roots,
            },
            .entries = entries.of(set),
            .packages = @import("source_packages.zig").entries,
            .interfaces = switch (set) {
                .main => &main_interfaces,
                .execution => &execution_interfaces,
                .host => &host_interfaces,
                else => &interfaces,
            },
        };

        const content = std.json.Stringify.valueAlloc(b.allocator, project, .{}) catch @panic("out of memory");

        run.addArg("--manifest");

        const name = b.fmt("{s}.json", .{@tagName(set)});

        _ = manifests.add(name, content);

        const manifest_path = declarations.manifests.path(b, name);

        if (set == .main) b.addNamedLazyPath("generation_manifest", manifest_path);

        run.addFileArg(manifest_path);
        run.addFileInput(b.dependency("zxc_std", .{}).path("interfaces/string.d.zx"));
        run.addFileInput(declarations.index);
        run.addFileInput(declarations.columns);

        if (set == .main) {
            run.addFileInput(roots[0].path(b, "zx/modules/path/lexical.d.zx"));
        }

        switch (set) {
            .collections => {
                addSources(run, tracked[2]);
                inline for (collection_roots) |path| addSubtree(run, tracked[3], path);
            },
            .execution => {
                run.addFileInput(roots[3].path(b, ownership_interface));
                run.addFileInput(lowering);
                addSubtree(run, tracked[0], "zx/modules");
                addSubtree(run, tracked[0], "zx/analysis/publication");
                addSubtree(run, tracked[0], "zx/frontend/retention");
                addSubtree(run, tracked[0], "rx/analysis/project/workflow");
                addSubtree(run, tracked[0], "rx/analysis/project/mixed");
                addSubtree(run, tracked[0], "backends/zig");
                addSubtree(run, tracked[0], "backends/hardware");
                addSubtree(run, tracked[0], "backends/verilog");
                addSubtree(run, tracked[0], "verification");
                addSources(run, tracked[2]);
                addSubtree(run, tracked[3], "analysis");
            },
            .host => {
                run.addFileInput(b.path(partition_interface));

                for (tracked[2..]) |inputs| addSources(run, inputs);
            },
            .growth => for (tracked[2..]) |inputs| addSources(run, inputs),
            else => for (tracked) |inputs| addSources(run, inputs),
        }

        const directory = run.addOutputDirectoryArg(@tagName(set));

        run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "bootstrap-functions"), .{ .make_absolute = true });

        // Partitioned output lives in one directory reused by every run, so unchanged partitions keep their
        // paths and contents and Zig reuses their objects; the generator itself skips work when inputs match.
        if (set == .main and partitions != 0) {
            run.addArgs(&.{ "--partitions", b.fmt("{d}", .{partitions}) });
            run.has_side_effects = true;
        }

        if (set == .constant_seed) {
            const install = b.addInstallDirectory(.{ .source_dir = directory, .install_dir = .prefix, .install_subdir = "bootstrap/constants" });

            b.step("bootstrap-constant-seed", "Generate the initial constant evaluator snapshot from RX and ZX").dependOn(&install.step);
        } else if (set == .snapshot_seed) {
            const install = b.addInstallDirectory(.{ .source_dir = directory, .install_dir = .prefix, .install_subdir = "bootstrap/input_snapshot" });

            b.step("bootstrap-input-snapshot", "Generate the initial input snapshot predicate from RX and ZX").dependOn(&install.step);
        } else if (set == .partition_seed) {
            const install = b.addInstallDirectory(.{ .source_dir = directory, .install_dir = .prefix, .install_subdir = "bootstrap/partition" });

            b.step("bootstrap-partition-seed", "Generate the initial partition planner from RX and ZX").dependOn(&install.step);
        } else {
            switch (set) {
                .main => sources.main = directory,
                .checks => sources.checks = directory,
                .collections => sources.collections = directory,
                .growth => sources.growth = directory,
                .execution => sources.execution = directory,
                .host => sources.host = directory,
                .constant_seed, .snapshot_seed, .partition_seed => unreachable,
            }
        }
    }

    return sources;
}

fn generatorRun(b: *std.Build, seed: *std.Build.Step.Compile, stage0: []const u8) *std.Build.Step.Run {
    if (stage0.len == 0) return b.addRunArtifact(seed);

    const run = b.addSystemCommand(&.{stage0});

    run.addFileInput(.{ .cwd_relative = stage0 });

    return run;
}

const collection_roots = [_][]const u8{ "analysis/state/locals", "analysis/state/queries", "analysis/members", "analysis/iteration/transfer/history" };
const SourceInput = struct { relative: []const u8, path: std.Build.LazyPath };

fn addSubtree(run: *std.Build.Step.Run, inputs: []const SourceInput, comptime directory: []const u8) void {
    const prefix = comptime blk: {
        var text = (directory ++ "/").*;

        std.mem.replaceScalar(u8, &text, '/', std.fs.path.sep);

        break :blk text;
    };

    for (inputs) |input| {
        if (std.mem.startsWith(u8, input.relative, &prefix)) run.addFileInput(input.path);
    }
}

fn addSources(run: *std.Build.Step.Run, inputs: []const SourceInput) void {
    for (inputs) |input| run.addFileInput(input.path);
}

fn sourceInputs(b: *std.Build, root: std.Build.LazyPath, absolute: []const u8) ![]const SourceInput {
    var directory = try std.Io.Dir.cwd().openDir(b.graph.io, absolute, .{ .iterate = true });

    defer directory.close(b.graph.io);

    var walker = try directory.walk(b.allocator);

    defer walker.deinit();
    b.dependOnDirectoryContents(root);

    var paths: std.ArrayList([]const u8) = .empty;

    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind == .directory) {
            b.dependOnDirectoryContents(root.path(b, entry.path));
        } else if (entry.kind == .file and (std.mem.endsWith(u8, entry.path, ".zx") or std.mem.endsWith(u8, entry.path, ".rx") or std.mem.endsWith(u8, entry.path, ".tpl"))) {
            try paths.append(b.allocator, try b.allocator.dupe(u8, entry.path));
        }
    }

    std.mem.sort([]const u8, paths.items, {}, lessThan);

    const inputs = try b.allocator.alloc(SourceInput, paths.items.len);

    for (paths.items, inputs) |path, *input| input.* = .{ .relative = path, .path = root.path(b, path) };

    return inputs;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Generated bootstrap modules omit debug information when strip is set; hand-written host modules keep theirs.
/// Native and standard modules every generated module shares; create them once per build so no file lands in two modules.
/// `objects` links the partition objects into an artifact that imports it; null when generated code is one unit.
/// `self_hosted_objects` are the same partitions compiled by Zig's own backend, which compiles an edited partition in
/// about 0.4 s instead of 1.5 s on x86_64 Debug. Code calling into them has to come from that backend too, since the
/// layout of Zig's own types only agrees within one backend, and only Apple's linker turns them into a runnable
/// executable on macOS; artifacts that cannot meet both keep `objects`. Each set compiles only when an artifact uses it.
/// They come as one directory holding `zxc_partition_<n>.o` for each partition.
pub const Shared = struct { generated: *std.Build.Module, checks: *std.Build.Module, collections: *std.Build.Module, growth: *std.Build.Module, execution: *std.Build.Module, objects: ?*std.Build.Module, self_hosted_objects: ?std.Build.LazyPath };

pub fn shared(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: Sources, strip: ?bool, partitions: u32) Shared {
    const abi = b.createModule(.{ .root_source_file = source.main.path(b, "types.zig"), .target = target, .optimize = optimize, .strip = strip });
    const memory = b.dependency("core", .{ .target = target, .optimize = optimize }).module("memory");

    const standard = b.createModule(.{
        .root_source_file = b.dependency("zxc_std", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zxc_abi", .module = abi }},
    });

    standard.addImport("sha256_backend", b.dependency("zxc_std", .{ .target = target, .optimize = optimize }).module("sha256_backend"));
    standard.addImport("bytes_backend", b.dependency("zxc_std", .{ .target = target, .optimize = optimize }).module("bytes_backend"));

    const string = b.createModule(.{ .root_source_file = b.dependency("zxc_std", .{}).path("src/string.zig"), .target = target, .optimize = optimize, .strip = strip });

    const generated = b.createModule(.{
        .root_source_file = source.main.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = standard },
            .{ .name = "zxc_string", .module = string },
            .{ .name = "memory", .module = memory },
            .{ .name = memory_columns, .module = memory },
            .{ .name = lexical_path, .module = standard },
        },
    });

    var objects: ?*std.Build.Module = null;
    var self_hosted_objects: ?std.Build.LazyPath = null;

    if (partitions != 0) {
        const bridge = b.createModule(.{ .root_source_file = b.path("build/partition/bridge.zig"), .target = target, .optimize = optimize, .strip = strip });

        const signatures = b.createModule(.{
            .root_source_file = source.main.path(b, "signatures.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "zxc_abi", .module = abi }},
        });

        const imports: []const std.Build.Module.Import = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = standard },
            .{ .name = "zxc_string", .module = string },
            .{ .name = "memory", .module = memory },
            .{ .name = memory_columns, .module = memory },
            .{ .name = lexical_path, .module = standard },
            .{ .name = "zxc_bridge", .module = bridge },
            .{ .name = "zxc_signatures", .module = signatures },
        };

        generated.addImport("zxc_bridge", bridge);
        generated.addImport("zxc_signatures", signatures);

        generated.addImport("zxc_comptime", b.createModule(.{
            .root_source_file = source.main.path(b, "original/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "zxc_abi", .module = abi },
                .{ .name = "zxc_standard", .module = standard },
                .{ .name = "zxc_string", .module = string },
                .{ .name = "memory", .module = memory },
                .{ .name = memory_columns, .module = memory },
                .{ .name = lexical_path, .module = standard },
            },
        }));

        objects = if (target.query.isNative()) cachedPartitionObjects(b, target, optimize, source, partitions, strip) else partitionObjects(b, target, optimize, source, partitions, imports, strip);

        if (optimize == .debug and target.result.cpu.arch == .x86_64 and target.query.isNative()) self_hosted_objects = cachedObjects(b, optimize, source, partitions, strip, false);
    }

    const check_modules = b.createModule(.{
        .root_source_file = source.checks.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = source.checks.path(b, "types.zig"), .target = target, .optimize = optimize, .strip = strip }) },
            .{ .name = "zxc_standard", .module = standard },
            .{ .name = "memory", .module = memory },
        },
    });

    const collections_abi = b.createModule(.{ .root_source_file = source.collections.path(b, "types.zig"), .target = target, .optimize = optimize, .strip = strip });

    const collections = b.createModule(.{
        .root_source_file = source.collections.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zxc_abi", .module = collections_abi },
            .{ .name = "zxc_standard", .module = standard },
            .{ .name = "zxc_string", .module = string },
            .{ .name = "memory", .module = memory },
        },
    });

    const growth_abi = b.createModule(.{ .root_source_file = source.growth.path(b, "types.zig"), .target = target, .optimize = optimize, .strip = strip });

    const growth = b.createModule(.{
        .root_source_file = source.growth.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zxc_abi", .module = growth_abi },
            .{ .name = "zxc_standard", .module = standard },
            .{ .name = "zxc_string", .module = string },
            .{ .name = "memory", .module = memory },
        },
    });

    const execution = b.createModule(.{
        .root_source_file = source.execution.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zxc_abi", .module = b.createModule(.{ .root_source_file = source.execution.path(b, "types.zig"), .target = target, .optimize = optimize, .strip = strip }) },
            .{ .name = "zxc_standard", .module = standard },
            .{ .name = "zxc_string", .module = string },
            .{ .name = "memory", .module = memory },
            .{ .name = memory_columns, .module = memory },
        },
    });

    return .{ .generated = generated, .checks = check_modules, .collections = collections, .growth = growth, .execution = execution, .objects = objects, .self_hosted_objects = self_hosted_objects };
}

/// Each partition is its own compilation unit; final artifacts link them by importing the returned module.
/// Generated bodies and their entry module use the same debug policy.
fn partitionObjects(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: Sources, partitions: u32, imports: []const std.Build.Module.Import, strip: ?bool) *std.Build.Module {
    const objects = b.createModule(.{ .root_source_file = b.path("build/partition/objects.zig"), .target = target, .optimize = optimize });

    for (0..partitions) |index| {
        const functions = b.createModule(.{
            .root_source_file = source.main.path(b, b.fmt("part_{d}/functions.zig", .{index})),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = imports,
        });

        const module = b.createModule(.{
            .root_source_file = source.main.path(b, b.fmt("part_{d}/root.zig", .{index})),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = imports,
        });

        module.addImport("zxc_functions", functions);
        objects.addObject(b.addObject(.{ .name = b.fmt("zxc_partition_{d}", .{index}), .root_module = module }));
    }

    return objects;
}

fn cachedPartitionObjects(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: Sources, partitions: u32, strip: ?bool) *std.Build.Module {
    const files = cachedObjects(b, optimize, source, partitions, strip, true);
    const objects = b.createModule(.{ .root_source_file = b.path("build/partition/objects.zig"), .target = target, .optimize = optimize });

    for (0..partitions) |index| objects.addObjectFile(files.path(b, b.fmt("zxc_partition_{d}.o", .{index})));

    return objects;
}

/// One manifest check replaces a Zig cache process per unchanged partition, on either native backend.
fn cachedObjects(b: *std.Build, optimize: std.builtin.OptimizeMode, source: Sources, partitions: u32, strip: ?bool, llvm: bool) std.Build.LazyPath {
    const rules = @import("host_metadata.zig").generated(b, source.host, b.graph.host, .small, true, null);

    const driver = b.createModule(.{
        .root_source_file = b.path("build/partition/compile.zig"),
        .target = b.graph.host,
        .optimize = .small,
        .imports = &.{
            .{ .name = "partition_rules", .module = rules },
            .{ .name = "partition_abi", .module = rules.import_table.get("zxc_abi").? },
            .{ .name = "file_manifest", .module = b.createModule(.{
                .root_source_file = b.path("src/backends/zig/output/manifest.zig"),
                .target = b.graph.host,
                .optimize = .small,
            }) },
        },
    });

    rules.addImport("partition_host", driver);

    const tool = b.addExecutable(.{ .name = "partition-objects", .root_module = driver });
    const run = b.addRunArtifact(tool);
    const level = b.fmt("-O{s}", .{@tagName(optimize)});
    const stripped: []const []const u8 = if (strip) |value| &.{if (value) "-fstrip" else "-fno-strip"} else &.{};

    run.addArg(b.graph.zig_exe);
    run.addDirectoryArg(source.main);

    const objects = run.addOutputDirectoryArg("objects");

    run.addArg(b.fmt("{d}", .{partitions}));
    run.addDirectoryArg(b.dependency("zxc_std", .{}).path("src"));
    run.addFileArg(b.path("build/partition/bridge.zig"));

    const memory = b.dependency("core", .{}).path("src/memory");

    run.addDirectoryArg(memory);
    run.addArgs(&.{ "--", "build-obj", if (llvm) "-fllvm" else "-fno-llvm", if (strip orelse false) "-fstrip" else "-fno-strip", level, "--dep", "zxc_bridge", "--dep", "zxc_functions", "-Mroot=%generated%/part_%index%/root.zig" });
    run.addArgs(stripped);
    run.addArgs(&.{ level, "-Mzxc_abi=%generated%/types.zig", level, "--dep", "zxc_abi", "--dep", "sha256_backend", "--dep", "bytes_backend", b.fmt("-Mzxc_standard={s}", .{b.dependency("zxc_std", .{}).builder.root.joinString(b.allocator, "src/root.zig") catch @panic("out of memory")}) });
    run.addArgs(stripped);
    run.addArgs(&.{ level, b.fmt("-Msha256_backend={s}", .{b.dependency("zxc_std", .{}).builder.root.joinString(b.allocator, "src/crypto/sha256.zig") catch @panic("out of memory")}) });
    run.addArgs(stripped);
    run.addArgs(&.{ level, b.fmt("-Mbytes_backend={s}", .{b.dependency("zxc_std", .{}).builder.root.joinString(b.allocator, "src/bytes/fast.zig") catch @panic("out of memory")}) });
    run.addArgs(stripped);
    run.addArgs(&.{ level, b.fmt("-Mzxc_string={s}", .{b.dependency("zxc_std", .{}).builder.root.joinString(b.allocator, "src/string.zig") catch @panic("out of memory")}) });
    run.addArgs(stripped);
    run.addArgs(&.{ level, "--dep", "sha256_backend" });
    run.addPrefixedFileArg("-Mmemory=", memory.path(b, "root.zig"));
    run.addArgs(stripped);
    run.addArgs(&.{ level, "--dep", "zxc_abi", "-Mzxc_signatures=%generated%/signatures.zig", level });
    run.addPrefixedFileArg("-Mzxc_bridge=", b.path("build/partition/bridge.zig"));
    run.addArgs(stripped);
    run.addArgs(&.{ level, "--dep", "zxc_abi", "--dep", "zxc_standard", "--dep", "zxc_string", "--dep", "memory", "--dep", memory_columns ++ "=memory", "--dep", lexical_path ++ "=zxc_standard", "--dep", "zxc_bridge", "--dep", "zxc_signatures", "-Mzxc_functions=%generated%/part_%index%/functions.zig" });
    run.addArgs(&.{ "--name", if (llvm) "zxc_partition_%index%" else "zxc_partition_%index%_self_hosted", "-femit-bin=%objects%/zxc_partition_%index%.o" });

    // The object directory persists across runs, so unchanged partitions keep their objects.
    run.has_side_effects = true;

    return objects;
}

pub fn modules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: Sources, natives: Shared, strip: ?bool) @import("compiler.zig").ParserModules {
    const type_views = @import("compiler.zig").typeViews(b, target, optimize);
    const nominal_data = @import("compiler.zig").nominalData(b, target, optimize);
    const bindings = b.allocator.alloc(@import("compiler.zig").ModuleBinding, entries.module_entries.len) catch @panic("out of memory");

    const host = @import("host_metadata.zig").generated(b, source.host, target, optimize, strip, .{
        .standard = natives.generated.import_table.get("zxc_standard").?,
        .string = natives.generated.import_table.get("zxc_string").?,
    });

    for (entries.module_entries, bindings) |metadata, *binding| {
        const directory = switch (metadata.set) {
            .main => source.main,
            .collections => source.collections,
            .growth => source.growth,
            .execution => source.execution,
            .host => source.host,
            else => unreachable,
        };

        const generated = switch (metadata.set) {
            .main => natives.generated,
            .collections => natives.collections,
            .growth => natives.growth,
            .execution => natives.execution,
            .host => host,
            else => unreachable,
        };

        const module = b.createModule(.{
            .root_source_file = directory.path(b, metadata.file),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });

        module.addImport("generated", generated);

        binding.* = .{ .metadata = metadata, .module = module };
    }

    return .{
        .type_views = type_views,
        .nominal_data = nominal_data,
        .bindings = bindings,
        .execution = natives.execution,
        .standard = natives.generated.import_table.get("zxc_standard").?,
        .host_metadata = @import("host_metadata.zig").create(b, source.host),
    };
}

/// Individual checkers only test builds import; they hang off one module's import table so tests can merge them.
pub fn checks(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: Sources, natives: Shared, strip: ?bool) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.addWriteFiles().add("checks.zig", ""), .target = target, .optimize = optimize });

    inline for (entries.checks) |entry| {
        module.addImport("generated_" ++ entry.name, b.createModule(.{
            .root_source_file = source.checks.path(b, entry.name ++ ".zig"),
            .strip = strip,
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "generated", .module = natives.checks }},
        }));
    }

    return module;
}
