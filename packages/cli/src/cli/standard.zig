const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const project = @import("project.zig");
const linkage = @import("cli_source").standard_linkage;

pub fn resolve(allocator: std.mem.Allocator, loaded: project.Loaded, required: []const []const u8, standard_root: []const u8, generated: []const compiler.zig.ModuleFile) !project.Loaded {
    const standard = compiler.project.standard;
    const configured = loaded.config.native_modules;
    const catalog_names = zx.memory.borrowTextColumn("module", standard);
    const catalog_paths = zx.memory.borrowTextColumn("implementation_path", standard);
    const configured_names = zx.memory.borrowTextColumn("name", configured);
    const generated_names = zx.memory.borrowTextColumn("name", generated);

    const input: std.meta.Child(linkage.Input) = .{
        .catalog = &.{
            .names = @ptrCast(&catalog_names),
            .paths = @ptrCast(&catalog_paths),
            .count = standard.len,
        },
        .configured = &.{ .names = @ptrCast(&configured_names), .count = configured.len },
        .generated = &.{ .names = @ptrCast(&generated_names), .count = generated.len },
        .required = required,
    };

    const plan = try zx.columns.invoke(linkage.executeValue, allocator, &input);

    switch (plan.status) {
        .Selected => {},
        .ReservedNativeModule => return error.ReservedNativeModule,
        .ConflictingModuleName => return error.ConflictingModuleName,
    }

    if (plan.additions.len == 0) return loaded;

    const modules = try allocator.alloc(project.NativeModule, configured.len + plan.additions.len);

    @memcpy(modules[0..configured.len], configured);

    for (modules[configured.len..], plan.additions) |*module, addition| {
        module.* = .{
            .name = addition.name,
            .path = try std.fs.path.resolve(allocator, &.{ standard_root, addition.path }),
            .dependencies = addition.dependencies,
        };
    }

    var result = loaded;

    result.config.native_modules = modules;

    return result;
}
