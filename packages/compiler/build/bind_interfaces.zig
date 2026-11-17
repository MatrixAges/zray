const std = @import("std");
const manifest = @import("generation_manifest.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 5) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    var input = try cwd.openDir(init.io, args[1], .{ .iterate = true });

    defer input.close(init.io);

    var output = try cwd.createDirPathOpen(init.io, args[4], .{});

    defer output.close(init.io);

    const declarations: manifest.Root = .{ .path = args[2], .prefix = args[3] };
    var entries = input.iterate();

    // Keep logical interface paths stable for native function names and old bootstrap tools.
    while (try entries.next(init.io)) |entry| {
        if (entry.kind != .file) continue;

        const template = try input.readFileAlloc(init.io, entry.name, allocator, .unlimited);
        var project = try std.json.parseFromSliceLeaky(manifest.Project, allocator, template, .{});
        project.roots = try std.mem.concat(allocator, manifest.Root, &.{ project.roots, &.{declarations} });
        const content = try std.json.Stringify.valueAlloc(allocator, project, .{});

        try output.writeFile(init.io, .{ .sub_path = entry.name, .data = content });
    }
}
