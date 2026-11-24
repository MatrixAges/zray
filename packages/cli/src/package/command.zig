const std = @import("std");
const manifest = @import("manifest.zig");
const constants = @import("cli_source").workspace_constants.@"zx.constants";

pub fn run(init: std.process.Init, request: anytype, args: []const []const u8, output: *std.Io.Writer, errors: *std.Io.Writer) !bool {
    const allocator = init.arena.allocator();
    const io = init.io;
    const path = request.path orelse constants.manifest_name;

    return switch (request.action) {
        .PackageInstall => @import("install.zig").run(io, allocator, args[1..], init.environ_map, output, errors),
        .PackageInit => @import("init.zig").run(io, allocator, args, output, errors),
        .PackageIndex, .PackageResolve => @import("index.zig").run(io, allocator, request, output, errors),
        .PackageInspect => inspect(io, allocator, path, output, errors),
        .PackageGraph => display(@import("graph.zig"), io, allocator, path, output, errors),
        .PackageWorkspace => display(@import("workspace.zig"), io, allocator, path, output, errors),
        .PackageUsage, .PackageIndexUsage => usage(request.action, errors),
        else => unreachable,
    };
}

pub const manifest_usage = "zxc pkg inspect|workspace|graph [pkg.yaml]\n";

fn usage(action: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
    if (action == .PackageIndexUsage) {
        try writer.writeAll(@import("index.zig").usage);
    } else {
        try writer.writeAll(manifest_usage);
        try writer.writeAll(@import("init.zig").usage);
        try writer.writeAll(@import("install.zig").usage);
    }

    return false;
}

fn display(comptime Loader: type, io: std.Io, allocator: std.mem.Allocator, path: []const u8, output: *std.Io.Writer, errors: *std.Io.Writer) !bool {
    var result = try Loader.load(io, allocator, path);

    defer result.deinit();

    if (result.diagnostic) |message| {
        try errors.print("{s}\n", .{message});

        return false;
    }

    if (Loader == @import("graph.zig")) {
        try @import("graph/display.zig").write(&result, output);
    } else try std.json.Stringify.value(result.packages, .{ .whitespace = .indent_2 }, output);

    try output.writeByte('\n');

    return true;
}

fn inspect(io: std.Io, allocator: std.mem.Allocator, path: []const u8, output: *std.Io.Writer, errors: *std.Io.Writer) !bool {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        if (err == error.OutOfMemory) return err;

        try errors.print("{s}: {s}\n", .{ path, @errorName(err) });

        return false;
    };

    defer allocator.free(source);

    var result = try manifest.parse(allocator, source);

    defer result.deinit();

    switch (result.value) {
        .diagnostic => |issue| {
            try errors.print("{s}:{d}:{d}: manifest: {s}\n", .{ path, issue.line, issue.column, issue.message });

            return false;
        },
        .data => |data| {
            try std.json.Stringify.value(data, .{ .whitespace = .indent_2 }, output);
            try output.writeByte('\n');
        },
    }

    return true;
}
