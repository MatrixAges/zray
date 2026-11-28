const std = @import("std");
const inventory = @import("../inventory.zig");
const rule = @import("cli_source").library_inventory_collect;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn collect(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const inventory.File {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var entries: StoreState = &.{ .paths = &.{}, .digests = &.{} };
    var host: StoreHost = .{ .store_0 = &entries };

    const outcome = try rule.execute(&arena, &.{
        .directory = path,
        .name = inventory.name,
    }, &host, io);

    if (!outcome.valid) return error.InvalidLibraryInventory;

    const files = try allocator.alloc(inventory.File, outcome.paths.len);
    var initialized: usize = 0;

    errdefer {
        for (files[0..initialized]) |item| {
            allocator.free(item.path);
            allocator.free(item.sha256);
        }

        allocator.free(files);
    }

    for (outcome.paths, outcome.digests, 0..) |entry_path, digest, index| {
        const owned_path = try allocator.dupe(u8, entry_path);

        errdefer allocator.free(owned_path);

        const owned_digest = try allocator.dupe(u8, digest);

        files[index] = .{ .path = owned_path, .sha256 = owned_digest };
        initialized += 1;
    }

    return files;
}
