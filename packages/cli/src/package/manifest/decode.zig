const std = @import("std");
const model = @import("model.zig");
const compiler = @import("compiler");
const rule = @import("cli_source").manifest_decode;
pub const Document = @import("manifest_yaml_document");
pub const Result = union(enum) { data: model.Manifest, diagnostic: model.Diagnostic };

pub fn read(allocator: std.mem.Allocator, document: *const Document) std.mem.Allocator.Error!Result {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const Entry = std.meta.Child(rule.Input);
    const Node = std.meta.Child(@FieldType(Entry, "node"));
    const nodes = try document.borrowNodes(scratch.allocator(), Node);

    const decoded = rule.executeIn(scratch.allocator(), &.{
        .document = nodes,
        .node = nodes[0],
        .version_limit = std.math.maxInt(usize),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (decoded.diagnostic) |issue| return .{ .diagnostic = .{
        .line = @intCast(issue.line),
        .column = @intCast(issue.column),
        .message = try dupeText(allocator, issue.message),
    } };

    const data = decoded.data.?;
    const exports = try allocator.alloc(model.Export, data.exports.len);

    for (data.exports, 0..) |item, i| {
        exports[i] = .{
            .path = try dupeText(allocator, item.path),
            .source = try dupeText(allocator, item.source),
            .module = if (item.module) |m| try dupeText(allocator, m) else null,
        };
    }

    const dependencies = try dupeDependencies(allocator, data.dependencies);
    const dev_dependencies = try dupeDependencies(allocator, data.dev_dependencies);
    const interfaces = try allocator.alloc(model.NativeInterface, data.native_interfaces.len);

    for (data.native_interfaces, 0..) |item, i| {
        interfaces[i] = .{
            .specifier = try dupeText(allocator, item.specifier),
            .path = try dupeText(allocator, item.path),
            .module = try dupeText(allocator, item.module),
            .namespace = try dupeTexts(allocator, item.namespace),
        };
    }

    const externals = try allocator.alloc(compiler.project.External, data.externals.len);

    for (data.externals, 0..) |item, i| {
        externals[i] = .{
            .specifier = try dupeText(allocator, item.specifier),
            .signature = try dupeText(allocator, item.signature),
            .export_name = if (item.export_name) |name| try dupeText(allocator, name) else null,
            .implementation = .{
                .module = try dupeText(allocator, item.implementation.module),
                .member = try dupeText(allocator, item.implementation.member),
                .allocator_argument = item.implementation.allocator_argument,
                .io_argument = item.implementation.io_argument,
                .process_argument = item.implementation.process_argument,
                .expand_tuple = item.implementation.expand_tuple,
                .errors = if (item.implementation.errors) |errs| try dupeTexts(allocator, errs) else null,
                .fallible = item.implementation.fallible,
                .concurrent = item.implementation.concurrent,
            },
        };
    }

    const modules = try allocator.alloc(model.NativeModule, data.native_modules.len);

    for (data.native_modules, 0..) |item, i| {
        const aliases = if (item.abi_aliases) |list| blk: {
            const copy = try allocator.alloc(model.AbiAlias, list.len);

            for (list, 0..) |alias, j| {
                copy[j] = .{
                    .name = try dupeText(allocator, alias.name),
                    .specifier = try dupeText(allocator, alias.specifier),
                };
            }

            break :blk copy;
        } else null;

        modules[i] = .{
            .name = try dupeText(allocator, item.name),
            .path = if (item.path) |p| try dupeText(allocator, p) else null,
            .header = if (item.header) |h| try dupeText(allocator, h) else null,
            .dependencies = try dupeTexts(allocator, item.dependencies),
            .bundle_files = try dupeTexts(allocator, item.bundle_files),
            .include_paths = if (item.include_paths) |paths| try dupeTexts(allocator, paths) else null,
            .abi_aliases = aliases,
        };
    }

    return .{ .data = .{
        .name = try dupeText(allocator, data.name),
        .version = try dupeText(allocator, data.version),
        .entry = if (data.entry) |entry| try dupeText(allocator, entry) else null,
        .library = if (data.library) |library| try dupeText(allocator, library) else null,
        .exports = exports,
        .private = data.private,
        .dependencies = dependencies,
        .dev_dependencies = dev_dependencies,
        .workspace = if (data.workspace) |packages| .{ .packages = try dupeTexts(allocator, packages) } else null,
        .native_interfaces = interfaces,
        .externals = externals,
        .native_modules = modules,
        .libraries = try dupeTexts(allocator, data.libraries),
        .include_paths = try dupeTexts(allocator, data.include_paths),
        .library_paths = try dupeTexts(allocator, data.library_paths),
    } };
}

fn dupeText(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return if (value.len == 0) "" else allocator.dupe(u8, value);
}

fn dupeTexts(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (values.len == 0) return &.{};

    const copy = try allocator.alloc([]const u8, values.len);

    for (values, 0..) |value, i| copy[i] = try dupeText(allocator, value);

    return copy;
}

fn dupeDependencies(allocator: std.mem.Allocator, values: anytype) std.mem.Allocator.Error![]const model.Dependency {
    if (values.len == 0) return &.{};

    const copy = try allocator.alloc(model.Dependency, values.len);

    for (values, 0..) |item, i| {
        copy[i] = .{
            .name = try dupeText(allocator, item.name),
            .requirement = try dupeText(allocator, item.requirement),
        };
    }

    return copy;
}
