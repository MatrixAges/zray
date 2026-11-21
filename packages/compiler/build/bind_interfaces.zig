const std = @import("std");
const manifest = @import("generation_manifest.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 5 or (args.len - 3) % 2 != 0) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    var input = try cwd.openDir(init.io, args[1], .{ .iterate = true });

    defer input.close(init.io);

    var output = try cwd.createDirPathOpen(init.io, args[args.len - 1], .{});

    defer output.close(init.io);

    const bindings = args[2 .. args.len - 1];
    const declarations = try allocator.alloc(manifest.Root, bindings.len / 2);

    for (declarations, 0..) |*root, index| {
        root.* = .{ .path = bindings[index * 2], .prefix = bindings[index * 2 + 1] };
    }

    var entries = input.iterate();

    // Keep logical interface paths stable for native function names and old bootstrap tools.
    while (try entries.next(init.io)) |entry| {
        if (entry.kind != .file) continue;

        const template = try input.readFileAlloc(init.io, entry.name, allocator, .unlimited);
        var project = try std.json.parseFromSliceLeaky(manifest.Project, allocator, template, .{});
        project.roots = try std.mem.concat(allocator, manifest.Root, &.{ project.roots, declarations });
        const content = try std.json.Stringify.valueAlloc(allocator, project, .{});

        try output.writeFile(init.io, .{ .sub_path = entry.name, .data = content });
    }
}
