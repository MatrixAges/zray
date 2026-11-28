const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const host = @import("publication_host");

pub fn publish(io: std.Io, backing: std.mem.Allocator, staging: []const u8, output: []const u8, managed: []const host.inventory.File, inputs: *Inputs) !bool {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const allocator = arena.allocator();
    const destination = try std.fs.path.resolve(allocator, &.{ inputs.cwd, output });
    var failure: host.Failure = .{};
    var directory: host.directory = .{ .io = io, .allocator = allocator, .failure = &failure, .source = staging };

    defer directory.deinit();

    const cursor = &directory;
    var verification: host.verification = .{ .io = io, .allocator = backing, .snapshot_allocator = backing, .inputs = inputs, .failure = &failure };

    defer verification.deinit();

    const observation = &verification;
    const managed_paths = try allocator.alloc([]const u8, managed.len);

    for (managed, managed_paths) |file, *path| path.* = file.path;

    const status = @import("cli_source").publish_library.executeIn(allocator, &.{
        .managed = managed_paths,
        .destination = destination,
        .directory = @ptrCast(&cursor),
        .verification = @ptrCast(&observation),
        .versioned = inputs.retain_versions,
        .observed = @ptrCast(&verification.observed),
        .separator = std.fs.path.sep,
    }, io) catch |err| return failure.unwrap(err);

    return switch (status) {
        .Changed => false,
        .Overlap => error.OutputOverlapsInput,
        .MissingInventory => error.MissingLibraryInventory,
        .Published => true,
    };
}
