const std = @import("std");
const library = @import("compiler").zig.host.library;
const project = @import("project.zig");
const Config = project.Config;
pub const GeneratedModule = library.Module;

pub fn render(allocator: std.mem.Allocator, config: Config, public_modules: []const GeneratedModule, generated: []const GeneratedModule, views: []const @import("abi.zig").File) library.Error![]u8 {
    const native = try allocator.alloc(library.Native, config.native_modules.len);

    defer allocator.free(native);

    for (config.native_modules, native) |module, *mapped| {
        const view = project.nativeIndex("module", views, module.name, true);

        mapped.* = .{
            .name = module.name,
            .path = module.path,
            .header = module.header,
            .dependencies = module.dependencies,
            .include_paths = module.include_paths orelse config.include_paths,
            .abi_view = if (view) |index| views[index].path else null,
        };
    }

    return library.render(allocator, .{
        .native = native,
        .generated = generated,
        .public = public_modules,
        .libraries = config.libraries,
        .library_paths = config.library_paths,
    });
}
