const std = @import("std");
const Options = @import("../options.zig").Options;
const Bundle = @import("compiler").zig.ModuleBundle;
const Self = @import("publication_host").application.Bindings;
const marker = Self.marker;

pub fn create(allocator: std.mem.Allocator, bundle: *const Bundle, options: Options) !Self {
    if (bundle.runner != null) return error.UnsupportedNodeRunner;

    const output = options.output.?;

    if (!std.mem.endsWith(u8, output, ".node")) return error.NodeAddonExtensionRequired;

    const signature = bundle.signature orelse return error.MissingNodeSignature;
    const stem = output[0 .. output.len - ".node".len];
    const relative = try std.fmt.allocPrint(allocator, "./{s}", .{std.fs.path.basename(output)});
    const path_literal = try std.json.Stringify.valueAlloc(allocator, relative, .{});

    return .{
        .module_path = try std.fmt.allocPrint(allocator, "{s}.cjs", .{stem}),
        .declaration_path = try std.fmt.allocPrint(allocator, "{s}.d.cts", .{stem}),
        .module_source = try std.fmt.allocPrint(allocator, "{s}const binding = require({s});\n\nexports.execute = binding.execute;\nexports.executeAsync = (...args) => new Promise((resolve, reject) => binding.executeTask(...args, resolve, reject));\n", .{ marker, path_literal }),
        .declarations = try @import("napi_declarations").render(allocator, signature.types, signature.input, signature.output),
    };
}
