const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const inventory = @import("../library/inventory.zig");
const retirement = @import("../library_resources.zig");
const paths = @import("../native_sources/path.zig");
const item = @import("cli_source").library_publication_item;
const columns = @import("zx").columns;

pub fn publish(io: std.Io, backing: std.mem.Allocator, staging: []const u8, output: []const u8, managed: []const inventory.File, inputs: *Inputs) !bool {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const allocator = arena.allocator();
    const destination = try std.fs.path.resolve(allocator, &.{ inputs.cwd, output });
    var observed = try inputs.observed(backing);
    var retained = false;

    defer if (!retained) observed.deinit();

    for (observed.entries) |entry| {
        const relative = try std.fs.path.relative(allocator, destination, null, destination, entry.path);

        if (paths.within(relative)) return error.OutputOverlapsInput;
    }

    if (!try inputs.verify(io, backing, observed)) return false;

    const retired = try retirement.retired(io, allocator, backing, destination, managed, inputs);
    var directory = try std.Io.Dir.openDirAbsolute(io, staging, .{ .iterate = true });

    defer directory.close(io);

    var walker = try directory.walk(allocator);

    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    var manifest = false;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (try walker.next(io)) |entry| {
        const role = columns.invoke(item.executeValue, empty.allocator(), &.{
            .path = @as([]const u8, entry.path),
            .regular = entry.kind == .file,
        }) catch unreachable;

        if (role == .Ignore) continue;

        const target = try std.fs.path.join(allocator, &.{ destination, entry.path });
        const physical = try @import("output.zig").check(io, allocator, inputs, target);

        allocator.free(physical);

        if (role == .Inventory) {
            manifest = true;
        } else {
            try files.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    if (!manifest) return error.MissingLibraryInventory;

    for (files.items) |path| {
        const target = try std.fs.path.join(allocator, &.{ destination, path });

        try directory.copyFile(path, .cwd(), target, io, .{ .make_path = true });
    }

    try retirement.remove(io, retired);
    try directory.copyFile(inventory.name, .cwd(), try std.fs.path.join(allocator, &.{ destination, inventory.name }), io, .{ .make_path = true });

    retained = inputs.retainPublished(observed);

    return true;
}
