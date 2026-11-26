const std = @import("std");
/// Lists generated files as one `<hash:016x> <path>` line per file.
pub const name = ".zxc-files";

/// The files a manifest lists, in the order they were written.
pub const Listed = struct {
    paths: []const []const u8,
    hashes: []const u64,
};

pub fn list(comptime generated: ?type, allocator: std.mem.Allocator, text: []const u8) !Listed {
    const count = std.mem.countScalar(u8, text, '\n') + 1;
    const paths = try allocator.alloc([]const u8, count);
    const hashes = try allocator.alloc(u64, count);
    var paths_buffer = paths;
    var hashes_buffer = hashes;

    const length = if (generated) |entry| try entry.executeValue(allocator, &.{
        .text = text,
        .paths = @ptrCast(&paths_buffer),
        .hashes = @ptrCast(&hashes_buffer),
    }) else try seedList(text, paths, hashes);

    return .{ .paths = paths[0..@intCast(length)], .hashes = hashes[0..@intCast(length)] };
}

fn seedList(text: []const u8, paths: [][]const u8, hashes: []u64) !usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var length: usize = 0;

    while (lines.next()) |line| {
        if (line.len < 18) continue;

        paths[length] = line[17..];
        hashes[length] = try std.fmt.parseInt(u64, line[0..16], 16);
        length += 1;
    }

    return length;
}

pub fn write(comptime generated: ?type, allocator: std.mem.Allocator, out: *std.Io.Writer, paths: []const []const u8, hashes: []const u64) !void {
    if (generated) |entry| {
        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        const text = try entry.executeIn(arena.allocator(), &.{ .paths = paths, .hashes = hashes });

        try out.writeAll(text);
    } else {
        for (paths, hashes) |path, hash| try out.print("{x:0>16} {s}\n", .{ hash, path });
    }
}
