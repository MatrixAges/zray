const std = @import("std");
const zx = @import("zx");
const source = @import("cli_source");
const disk = @import("artifact_io");
pub const write = disk.write;

pub const Prepared = struct {
    directory: []const u8,
    module_paths: []const []const u8,
};

pub fn prepare(io: std.Io, allocator: std.mem.Allocator, bundle: *const @import("compiler").zig.ModuleBundle, runner_override: ?[]const u8, configuration: []const u8, abi: @import("abi.zig").Result, emit_result: bool) !Prepared {
    const result = try @import("compiler").zig.host.result(allocator, emit_result);

    defer allocator.free(result);

    const supplied = runner_override orelse bundle.runner;

    const runner = supplied orelse runner: {
        const signature = bundle.signature orelse return error.MissingApplicationSignature;

        break :runner try @import("compiler").zig.host.cli(allocator, bundle.state_module != null, .{ .types = signature.types, .id = signature.output });
    };

    defer if (supplied == null) allocator.free(runner);

    const graph = try std.json.Stringify.valueAlloc(allocator, .{ .entry = bundle.entry.imports, .modules = bundle.modules, .abi_views = abi.views, .state_module = bundle.state_module }, .{});

    defer allocator.free(graph);

    var context: disk.Context = .{ .io = io };
    const view_paths = zx.memory.borrowTextColumn("path", abi.views);
    const view_sources = zx.memory.borrowTextColumn("source", abi.views);
    const names = zx.memory.borrowTextColumn("name", bundle.modules);
    const sources = zx.memory.borrowTextColumn("source", bundle.modules);

    const prepared = source.workspace_build.executeValue(allocator, &.{
        .fs = @ptrCast(&context),
        .separator = &.{std.fs.path.sep},
        .identity = &.{
            .entry = bundle.entry.source,
            .abi = abi.source,
            .runner = runner,
            .result = result,
            .configuration = configuration,
            .graph = graph,
        },
        .views = &.{ .count = abi.views.len, .paths = @ptrCast(&view_paths), .sources = @ptrCast(&view_sources) },
        .modules = &.{ .count = bundle.modules.len, .paths = @ptrCast(&names), .sources = @ptrCast(&sources) },
    }) catch |err| return context.unwrap(err);

    return .{ .directory = prepared.directory, .module_paths = prepared.module_paths };
}

pub fn retain(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    var context: disk.Context = .{ .io = io };
    const needs_write = source.workspace_retain.executeIn(allocator, &.{ .fs = @ptrCast(&context), .path = path, .source = content }) catch |err| return context.unwrap(err);

    if (needs_write) try context.writeFile(path, content);
}
