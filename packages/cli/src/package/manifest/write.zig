const std = @import("std");
const model = @import("model.zig");
const memory = @import("zx").memory;
const rule = @import("cli_source").manifest_write;
const Input = std.meta.Child(rule.Input);

pub fn write(allocator: std.mem.Allocator, target: *std.Io.Writer, data: model.Manifest) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const exports = columns("exports", &.{}, data.exports);
    const dependencies = columns("dependencies", &.{}, data.dependencies);
    const dev_dependencies = columns("dev_dependencies", &.{}, data.dev_dependencies);
    const interfaces = columns("interfaces", &.{}, data.native_interfaces);
    const externals = columns("externals", &.{}, data.externals);
    const implementations = columns("implementations", &.{"implementation"}, data.externals);
    const modules = columns("modules", &.{}, data.native_modules);
    const names = memory.borrowOptionalListColumn("abi_aliases", "name", data.native_modules);
    const specifiers = memory.borrowOptionalListColumn("abi_aliases", "specifier", data.native_modules);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const rendered = rule.executeValue(arena.allocator(), &Input{
        .identity = &.{
            .name = data.name,
            .version = data.version,
            .entry = data.entry,
            .library = data.library,
        },
        .exports = &exports.view(),
        .private = data.private,
        .dependencies = &dependencies.view(),
        .dev_dependencies = &dev_dependencies.view(),
        .workspace = if (data.workspace) |workspace| workspace.packages else null,
        .interfaces = &interfaces.view(),
        .externals = &externals.view(),
        .implementations = &implementations.view(),
        .modules = &modules.view(),
        .aliases = &.{
            .name = @ptrCast(&names),
            .specifier = @ptrCast(&specifiers),
        },
        .libraries = data.libraries,
        .include_paths = data.include_paths,
        .library_paths = data.library_paths,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    try target.writeAll(rendered);
}

fn columns(comptime name: []const u8, comptime prefix: []const []const u8, rows: anytype) Columns(std.meta.Child(@FieldType(Input, name))) {
    return .init(prefix, rows);
}

fn Columns(comptime View: type) type {
    const names = @typeInfo(View).@"struct".field_names;

    return struct {
        const Self = @This();

        storage: [names.len]memory.ReadColumn = undefined,
        count: usize,
        fn init(comptime prefix: []const []const u8, rows: anytype) Self {
            var self: Self = .{ .count = rows.len };

            inline for (names, &self.storage) |name, *column| {
                if (comptime !std.mem.eql(u8, name, "count")) {
                    const path = comptime prefix[0..prefix.len].* ++ [1][]const u8{name};
                    const field = comptime memory.columnFieldLayout(std.meta.Child(@TypeOf(rows)), &path);

                    column.* = memory.borrowNestedColumn(field.type, &path, rows);
                }
            }

            return self;
        }
        fn view(self: *const Self) View {
            var result: View = undefined;

            inline for (names, &self.storage) |name, *column| {
                @field(result, name) = if (comptime std.mem.eql(u8, name, "count")) self.count else @ptrCast(column);
            }

            return result;
        }
    };
}
