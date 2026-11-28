const std = @import("std");
const Options = @import("../options.zig").Options;
const Bundle = @import("compiler").zig.ModuleBundle;
const Self = @import("publication_host").bindings;
const source = @import("cli_source");
const marker = Self.marker;
const constants = source.node_binding_constants.@"zx.constants";

pub fn create(allocator: std.mem.Allocator, bundle: *const Bundle, options: Options) !Self {
    if (bundle.runner != null) return error.UnsupportedNodeRunner;

    const output = options.output.?;

    if (!std.mem.endsWith(u8, output, constants.addon_extension)) return error.NodeAddonExtensionRequired;

    const signature = bundle.signature orelse return error.MissingNodeSignature;
    const paths = try source.node_binding_paths.executeValue(allocator, output);
    const path_literal = try std.json.Stringify.valueAlloc(allocator, paths.relative, .{});

    return .{
        .module_path = paths.module,
        .declaration_path = paths.declaration,
        .module_source = try std.fmt.allocPrint(allocator, "{s}const binding = require({s});\n\nexports.execute = binding.execute;\nexports.executeAsync = (...args) => new Promise((resolve, reject) => binding.executeTask(...args, resolve, reject));\n", .{ marker, path_literal }),
        .declarations = try @import("napi_declarations").render(allocator, signature.types, signature.input, signature.output),
    };
}
