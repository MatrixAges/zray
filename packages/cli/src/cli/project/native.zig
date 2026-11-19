const std = @import("std");
const compiler = @import("compiler");
const Inputs = @import("../watch/inputs.zig");
const Config = @import("../../package/manifest/model.zig").Manifest;

pub fn load(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8, config: Config, inputs: ?*Inputs) ![]compiler.project.NativeInterface {
    const configuration = compiler.project.native_configuration;

    try configuration.validateExternals(config.externals);

    const interfaces = try allocator.alloc(compiler.project.NativeInterface, config.native_interfaces.len);

    for (config.native_interfaces, interfaces) |declaration, *interface| {
        try configuration.validateInterface(declaration.specifier, declaration.path);

        const interface_path = try std.fs.path.resolve(allocator, &.{ root_dir, declaration.path });

        if (inputs) |observed| try observed.add(io, interface_path);

        const interface_source = try std.Io.Dir.cwd().readFileAlloc(io, interface_path, allocator, .limited(16 * 1024 * 1024));

        if (inputs) |observed| try observed.record(io, interface_path, interface_source);

        interface.* = .{
            .specifier = declaration.specifier,
            .path = interface_path,
            .source = interface_source,
            .module = declaration.module,
            .namespace = declaration.namespace,
        };
    }

    try configuration.validateModules(config.native_modules);

    return interfaces;
}
