const std = @import("std");
const c = @import("yaml.zig").c;
const model = @import("model.zig");
const memory = @import("zx").memory;
const compiler = @import("compiler");
const rule = @import("cli_source").manifest_decode;
pub const Document = @import("manifest_yaml_document");
pub const Error = error{ OutOfMemory, InvalidManifest };
const Input = std.meta.Child(rule.Input);
const Tables = std.meta.Child(@FieldType(Input, "tables"));

const Exports = Destination("exports", model.Export, .{
    .path = &.{"path"},
    .source = &.{"source"},
    .module = &.{"module"},
});

const Dependencies = Destination("dependencies", model.Dependency, .{
    .name = &.{"name"},
    .requirement = &.{"requirement"},
});

const Interfaces = Destination("interfaces", model.NativeInterface, .{
    .specifier = &.{"specifier"},
    .path = &.{"path"},
    .module = &.{"module"},
    .namespace = &.{"namespace"},
});

const Modules = Destination("modules", model.NativeModule, .{
    .name = &.{"name"},
    .path = &.{"path"},
    .header = &.{"header"},
    .dependencies = &.{"dependencies"},
    .bundle_files = &.{"bundle_files"},
    .include_paths = &.{"include_paths"},
    .abi_aliases = &.{"abi_aliases"},
});

const Aliases = Destination("aliases", model.AbiAlias, .{
    .name = &.{"name"},
    .specifier = &.{"specifier"},
});

const Externals = Destination("externals", compiler.project.External, .{
    .identity = &.{"identity"},
    .specifier = &.{"specifier"},
    .signature = &.{"signature"},
    .export_name = &.{"export_name"},
    .module = &.{ "implementation", "module" },
    .member = &.{ "implementation", "member" },
    .allocator_argument = &.{ "implementation", "allocator_argument" },
    .io_argument = &.{ "implementation", "io_argument" },
    .process_argument = &.{ "implementation", "process_argument" },
    .expand_tuple = &.{ "implementation", "expand_tuple" },
    .errors = &.{ "implementation", "errors" },
    .fallible = &.{ "implementation", "fallible" },
    .concurrent = &.{ "implementation", "concurrent" },
});

pub fn read(allocator: std.mem.Allocator, document: *Document, root: *const c.yaml_node_t) Error!model.Manifest {
    var exports: Exports = undefined;
    var dependencies: Dependencies = undefined;
    var dev_dependencies: Dependencies = undefined;
    var interfaces: Interfaces = undefined;
    var modules: Modules = undefined;
    var aliases: Aliases = undefined;
    var externals: Externals = undefined;
    var strings: [][]const u8 = &.{};

    exports.rows.init();
    dependencies.rows.init();
    dev_dependencies.rows.init();
    interfaces.rows.init();
    modules.rows.init();
    aliases.rows.init();
    externals.rows.init();

    const data = rule.executeValue(allocator, &Input{
        .document = @ptrCast(document),
        .node = @ptrCast(root),
        .tables = &.{
            .exports = &exports.view(),
            .dependencies = &dependencies.view(),
            .dev_dependencies = &dev_dependencies.view(),
            .interfaces = &interfaces.view(),
            .modules = &modules.view(),
            .aliases = &aliases.view(),
            .externals = &externals.view(),
            .strings = @ptrCast(&strings),
        },
    }) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidManifest => |failure| return failure,
        else => unreachable,
    };

    return .{
        .name = data.name,
        .version = data.version,
        .entry = data.entry,
        .library = data.library,
        .exports = exports.rows.rows(),
        .private = data.private,
        .dependencies = dependencies.rows.rows(),
        .dev_dependencies = dev_dependencies.rows.rows(),
        .workspace = if (data.workspace) |packages| .{ .packages = packages } else null,
        .native_interfaces = interfaces.rows.rows(),
        .externals = externals.rows.rows(),
        .native_modules = modules.rows.rows(),
        .libraries = data.libraries,
        .include_paths = data.include_paths,
        .library_paths = data.library_paths,
    };
}

fn Destination(comptime name: []const u8, comptime Row: type, comptime fields: anytype) type {
    const View = std.meta.Child(@FieldType(Tables, name));
    const Columns = std.meta.Child(@FieldType(View, "columns"));

    return struct {
        const Self = @This();

        rows: memory.RowOutput(Row, Columns, fields),
        fn view(self: *const Self) View {
            return .{ .buffer = @ptrCast(&self.rows.buffer), .columns = &self.rows.view };
        }
    };
}
