const std = @import("std");
const pkgs = @import("pkgs");
pub const usage = "zxc pkg index [index.json]\nzxc pkg resolve <name> <range> [index.json]\n";

pub fn run(io: std.Io, allocator: std.mem.Allocator, request: anytype, output: *std.Io.Writer, errors: *std.Io.Writer) !bool {
    const path = request.path;

    const source = if (path) |file| std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.OutOfMemory) return err;

        try errors.print("{s}: index: {s}\n", .{ file, @errorName(err) });

        return false;
    } else @import("bundle").index;

    defer if (path != null) allocator.free(source);

    const parsed = pkgs.Index.parse(allocator, source) catch |err| {
        if (err == error.OutOfMemory) return err;

        try errors.print("{s}: index: {s}\n", .{ path orelse "embedded index", @errorName(err) });

        return false;
    };

    defer parsed.deinit();

    if (request.name) |name| {
        const range = request.range.?;

        const release = parsed.value.select(name, range) catch |err| {
            try errors.print("{s}: {s}: {s}\n", .{ name, range, @errorName(err) });

            return false;
        };

        if (release == null) {
            try errors.print("{s}: no indexed version satisfies {s}\n", .{ name, range });

            return false;
        }

        try std.json.Stringify.value(release.?, .{ .whitespace = .indent_2 }, output);
    } else try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, output);

    try output.writeByte('\n');

    return true;
}
