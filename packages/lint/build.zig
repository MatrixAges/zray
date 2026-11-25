const std = @import("std");

const Rule = struct {
    name: []const u8,
    seed_path: []const u8,
    root_path: []const u8,
};

const rules = [_]Rule{
    .{ .name = "lint_layout", .seed_path = "src/layout/rule.zig", .root_path = "src/layout/rule.zig" },
    .{ .name = "lint_rx", .seed_path = "src/rx/rule.zig", .root_path = "src/rx/rule.zig" },
    .{ .name = "lint_config", .seed_path = "src/configuration/rule.zig", .root_path = "src/configuration/rule.zig" },
    .{ .name = "naming", .seed_path = "bootstrap/naming.zig", .root_path = "src/naming/root.zig" },
    .{ .name = "spacing_boundary", .seed_path = "bootstrap/spacing_boundary.zig", .root_path = "src/spacing/boundary/root.zig" },
    .{ .name = "import_order", .seed_path = "bootstrap/import_order.zig", .root_path = "src/imports/order/root.zig" },
    .{ .name = "condition_policy", .seed_path = "bootstrap/condition_policy.zig", .root_path = "src/condition/policy.zig" },
    .{ .name = "loop_postfix", .seed_path = "bootstrap/loop_postfix.zig", .root_path = "src/loop/postfix.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const seed = b.option(bool, "seed", "Use the initial Zig lint implementations") orelse false;
    const generated = b.option(std.Build.LazyPath, "generated", "Generated RX/ZX lint directory");

    if (seed and generated != null) @panic("seed lint cannot use generated rules");
    if (!seed and generated == null) @panic("lint requires generated directory; seed is only for bootstrap");

    const module = b.addModule("lint", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dsl", .module = b.dependency("dsl", .{ .target = target, .optimize = optimize }).module("dsl") },
            .{ .name = "zx", .module = b.dependency("core", .{ .target = target, .optimize = optimize }).module("core") },
        },
    });

    for (rules) |rule| {
        if (seed and
            !std.mem.eql(u8, rule.name, "naming") and
            !std.mem.eql(u8, rule.name, "condition_policy") and
            !std.mem.eql(u8, rule.name, "loop_postfix") and
            !std.mem.eql(u8, rule.name, "import_order") and
            !std.mem.eql(u8, rule.name, "spacing_boundary")) continue;

        const rule_module = b.createModule(.{
            .root_source_file = b.path(if (seed) rule.seed_path else rule.root_path),
            .target = target,
            .optimize = optimize,
        });

        if (generated) |directory| {
            rule_module.addImport("generated", b.createModule(.{
                .root_source_file = directory.path(b, b.fmt("{s}.zig", .{rule.name})),
                .target = target,
                .optimize = optimize,
            }));
        }

        module.addImport(rule.name, rule_module);
    }

    const library = b.addLibrary(.{ .name = "zxc_lint", .root_module = module });

    b.installArtifact(library);
}
