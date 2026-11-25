const std = @import("std");
const library = @import("compiler").zig.host.library;
const zx = @import("zx");
const project = @import("project.zig");
const Config = project.Config;
const memory = zx.memory;
const bind_views = @import("cli_source").library_native_views;
const Input = std.meta.Child(bind_views.Input);
const input_fields = .{ .names = "name", .paths = "path", .headers = "header", .dependencies = "dependencies", .include_paths = "include_paths" };
const output_fields = .{ .names = "name", .paths = "path", .headers = "header", .dependencies = "dependencies", .include_paths = "include_paths", .abi_views = "abi_view" };

pub fn render(allocator: std.mem.Allocator, config: Config, public_modules: []const library.Module, generated: []const library.Module, views: []const @import("abi.zig").File) library.Error![]u8 {
    const native = try allocator.alloc(library.Native, config.native_modules.len);

    defer allocator.free(native);

    if (native.len != 0) {
        const modules = memory.borrowReadFields(input_fields, config.native_modules);
        const target = memory.borrowWriteFields(output_fields, native);
        const names = memory.borrowTextColumn("module", views);
        const paths = memory.borrowTextColumn("path", views);
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(bind_views.executeValue, fixed.allocator(), &Input{
            .modules = &modules.bind(std.meta.Child(@FieldType(Input, "modules"))),
            .views = &.{ .count = views.len, .names = @ptrCast(&names), .paths = @ptrCast(&paths) },
            .includes = config.include_paths,
            .target = &target.bind(std.meta.Child(@FieldType(Input, "target"))),
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
