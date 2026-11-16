const std = @import("std");

pub fn create(b: *std.Build, source: std.Build.LazyPath) *std.Build.Step.Compile {
    const target = b.graph.host;
    const optimize: std.builtin.OptimizeMode = .small;
    const modules = generated(b, source, target, optimize, true, null);
    const options = b.addOptions();

    options.addOption(bool, "generated", true);
    options.addOption(bool, "generated_analysis", true);

    const genz = b.createModule(.{
        .root_source_file = b.dependency("genz", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zx", .module = b.dependency("core", .{ .target = target, .optimize = optimize }).module("core") },
            .{ .name = "genz_options", .module = options.createModule() },
        },
    });

    inline for (@import("entries.zig").host) |entry| {
        genz.addImport(entry.importName(), b.createModule(.{
            .root_source_file = source.path(b, entry.name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "generated", .module = modules }},
        }));
    }

    return b.addExecutable(.{
        .name = "host-metadata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/generate_metadata.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "genz", .module = genz }},
        }),
    });
}

const NativeImports = struct { standard: *std.Build.Module, string: *std.Build.Module };

pub fn generated(b: *std.Build, source: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: ?bool, shared: ?NativeImports) *std.Build.Module {
    const abi = b.createModule(.{ .root_source_file = source.path(b, "types.zig"), .target = target, .optimize = optimize, .strip = strip });

    const natives = shared orelse NativeImports{
        .standard = standardModule(b, target, optimize, abi),
        .string = b.createModule(.{ .root_source_file = b.dependency("zxc_std", .{}).path("src/string.zig"), .target = target, .optimize = optimize, .strip = strip }),
    };

    return b.createModule(.{
        .root_source_file = source.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = natives.standard },
            .{ .name = "zxc_string", .module = natives.string },
            .{ .name = "zxc_compiler_memory", .module = b.dependency("core", .{ .target = target, .optimize = optimize }).module("compiler_memory") },
        },
    });
}

fn standardModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, abi: *std.Build.Module) *std.Build.Module {
    const standard = b.dependency("zxc_std", .{ .target = target, .optimize = optimize });

    return b.createModule(.{
        .root_source_file = standard.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "bytes_backend", .module = standard.module("bytes_backend") },
        },
    });
}
