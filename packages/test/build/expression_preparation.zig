const std = @import("std");

pub fn add(b: *std.Build, programs: @import("parser_programs.zig").Programs, compiler: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const step = b.step("test-expression-preparation", "Validate generated expression lookahead across root and interpolation token streams");
    const semantics_step = b.step("test-expression-preparation-semantics", "Validate expression lookahead classification and stream alignment");
    const resources_step = b.step("test-expression-preparation-resources", "Validate expression preparation allocation failures and result lifetime");
    const frontend = compiler.module("frontend");

    for ([_][]const u8{ "direct", "module" }) |route| {
        const program = programs.byteInput(b, b.fmt("expression_{s}", .{route}));

        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bootstrap/expression_preparation/semantics_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "program", .module = program },
                .{ .name = "zx", .module = frontend.import_table.get("zx").? },
                .{ .name = "lexer", .module = frontend.import_table.get("lexer").? },
            },
        }) });

        semantics_step.dependOn(&b.addRunArtifact(tests).step);

        const resources = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bootstrap/expression_preparation/resources_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "program", .module = program }},
        }) });

        resources.root_module.addAnonymousImport("allocation_testing", .{ .root_source_file = b.path("tests/support/allocation_testing.zig"), .target = target, .optimize = optimize });
        resources_step.dependOn(&b.addRunArtifact(resources).step);
    }

    step.dependOn(semantics_step);
    step.dependOn(resources_step);

    return step;
}
