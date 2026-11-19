const std = @import("std");
const Lock = @import("pkgs").Lock;
const model = @import("model.zig");

pub fn prepare(io: std.Io, allocator: std.mem.Allocator, lock: Lock, root: []const u8, cache: []const u8, offline: bool) !model.Prepared {
    const paths = try allocator.alloc([]const u8, lock.packages.len);
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer scratch.deinit();

    for (lock.packages, paths) |package, *path| {
        const location = switch (package.source) {
            .workspace => |relative| try std.fs.path.resolve(allocator, &.{ root, relative }),
            .archive => |source| try @import("../store.zig").prepare(io, allocator, .{ .version = package.version, .archive = source.archive, .sha256 = source.sha256 }, root, cache, offline),
        };

        path.* = try std.Io.Dir.cwd().realPathFileAlloc(io, location, allocator);

        if (package.source == .archive) {
            const memory = scratch.allocator();
            const data = try model.read(io, memory, path.*, null, memory);

            if (!model.matches(data, package)) return error.InstalledManifestDoesNotMatchLock;

            _ = scratch.reset(.retain_capacity);
        }
    }

    return .{ .lock = lock, .paths = paths };
}
