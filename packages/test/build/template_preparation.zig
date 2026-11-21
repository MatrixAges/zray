const std = @import("std");

pub fn add(b: *std.Build, programs: @import("parser_programs.zig").Programs, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const step = b.step("test-template-preparation", "Validate generated template preparation semantics and resources");
    const resources_step = b.step("test-template-preparation-resources", "Validate generated template preparation allocation cleanup and result lifetime");
    const semantics_step = b.step("test-template-preparation-semantics", "Validate generated template parts references and interpolation metadata");
    const frontend = compiler.module("frontend");
    const zx = frontend.import_table.get("zx").?;

    const native_template = b.createModule(.{
        .root_source_file = compiler.path("src/zx/frontend/template.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zx", .module = zx }},
    });

    for ([_][]const u8{ "direct", "module" }) |route| {
        const program = programs.byteInput(b, b.fmt("template_{s}", .{route}));

        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bootstrap/template_preparation/resources_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "program", .module = program }},
        }) });

        tests.root_module.addAnonymousImport("allocation_testing", .{ .root_source_file = b.path("tests/support/allocation_testing.zig"), .target = target, .optimize = optimize });
        resources_step.dependOn(&b.addRunArtifact(tests).step);

        const semantics = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bootstrap/template_preparation/semantics_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "program", .module = program },
                .{ .name = "zx", .module = zx },
                .{ .name = "lexer", .module = frontend.import_table.get("lexer").? },
                .{ .name = "native_template", .module = native_template },
            },
        }) });

        semantics_step.dependOn(&b.addRunArtifact(semantics).step);
    }

    step.dependOn(resources_step);
    step.dependOn(semantics_step);

    return step;
}
