const std = @import("std");
const source_inputs = @import("source_inputs.zig");

pub const Programs = struct {
    output: std.Build.LazyPath,
    generated: *std.Build.Module,
    pub fn entry(self: Programs, b: *std.Build, name: []const u8) *std.Build.Module {
        return b.createModule(.{
            .root_source_file = self.output.path(b, b.fmt("{s}.zig", .{name})),
            .target = self.generated.resolved_target,
            .optimize = self.generated.optimize,
            .imports = &.{.{ .name = "generated", .module = self.generated }},
        });
    }

    pub fn byteInput(self: Programs, b: *std.Build, name: []const u8) *std.Build.Module {
        return b.createModule(.{
            .root_source_file = b.path("tests/bootstrap/byte_input.zig"),
            .target = self.generated.resolved_target,
            .optimize = self.generated.optimize,
            .imports = &.{.{ .name = "entry", .module = self.entry(b, name) }},
        });
    }
};

pub fn create(b: *std.Build, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Programs {
    const prepare = b.addSystemCommand(&.{"node"});

    prepare.addFileArg(b.path("tests/bootstrap/parser_manifest.ts"));
    prepare.addFileArg(compiler.namedLazyPath("generation_manifest"));
    prepare.addDirectoryArg(b.path("tests/bootstrap"));

    const manifest = prepare.addOutputFileArg("parser_fixtures.json");
    const generate = std.Build.Step.Run.create(b, "generate-parser-fixtures");

    generate.addFileArg(compiler.namedLazyPath("source_generator"));
    generate.addArg("--manifest");
    generate.addFileArg(manifest);

    const output = generate.addOutputDirectoryArg("parser_fixtures");

    _ = generate.addOutputDirectoryArg("cache");

    generate.setEnvironmentVariable("ZXC_RESIDENT_GENERATOR", "0");
    generate.addFileInput(compiler.namedLazyPath("memory_interface"));
    generate.addFileInput(compiler.namedLazyPath("memory_columns_interface"));
    generate.addFileInput(b.path("../core/src/const.zx"));
    generate.addFileInput(b.path("../core/src/ascii/const.zx"));

    for ([_][]const u8{ "lexer", "parser" }) |path| {
        source_inputs.add(b, generate, compiler, b.fmt("src/zx/frontend/{s}", .{path})) catch @panic("unable to track parser fixture sources");
    }

    generate.addFileInput(compiler.path("src/zx/frontend/lexical.rx"));
    generate.addFileInput(compiler.path("src/zx/frontend/storage.zx"));
    generate.addFileInput(b.path("tests/bootstrap/expression_preparation/source.rx"));
    generate.addFileInput(b.path("tests/bootstrap/type_parser/source.rx"));

    const frontend = compiler.module("frontend");
    const shared = frontend.import_table.get("generated_parser").?.import_table.get("generated").?;
    const abi = b.createModule(.{ .root_source_file = output.path(b, "types.zig"), .target = target, .optimize = optimize });

    const generated = b.createModule(.{
        .root_source_file = output.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zxc_abi", .module = abi },
            .{ .name = "zxc_standard", .module = shared.import_table.get("zxc_standard").? },
            .{ .name = "zxc_string", .module = shared.import_table.get("zxc_string").? },
            .{ .name = "memory", .module = shared.import_table.get("memory").? },
        },
    });

    return .{ .output = output, .generated = generated };
}
