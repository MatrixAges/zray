const std = @import("std");
const library = @import("compiler").zig.host.library;
const zx = @import("zx");
const project = @import("project.zig");
const Config = project.Config;
const bind_views = @import("cli_source").library_native_views;

pub fn render(allocator: std.mem.Allocator, config: Config, public_modules: []const library.Module, generated: []const library.Module, views: []const @import("abi.zig").File) library.Error![]u8 {
    const native = try allocator.alloc(library.Native, config.native_modules.len);

    defer allocator.free(native);

    for (config.native_modules, native) |module, *mapped| {
        mapped.* = .{
            .name = module.name,
            .path = module.path,
            .header = module.header,
            .dependencies = module.dependencies,
            .include_paths = module.include_paths orelse config.include_paths,
            .abi_view = null,
        };
    }

    if (views.len != 0) {
        const names = zx.memory.borrowTextColumn("name", native);
        const modules = zx.memory.borrowTextColumn("module", views);
        const paths = zx.memory.borrowTextColumn("path", views);
        const target = zx.memory.borrowWriteColumn(?[]const u8, "abi_view", native);
        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        const Input = std.meta.Child(bind_views.Input);

        zx.columns.invoke(bind_views.executeValue, fixed.allocator(), &Input{
            .modules = &.{ .count = native.len, .names = @ptrCast(&names) },
            .views = &.{ .count = views.len, .names = @ptrCast(&modules), .paths = @ptrCast(&paths) },
            .target = @ptrCast(&target),
        }) catch unreachable;
    }

    return library.render(allocator, .{
        .native = native,
        .generated = generated,
        .public = public_modules,
        .libraries = config.libraries,
        .library_paths = config.library_paths,
    });
}
