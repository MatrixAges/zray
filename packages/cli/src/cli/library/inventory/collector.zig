const std = @import("std");
const Directory = @import("../../publication/directory.zig");
const effects = @import("../../publication/effects.zig");
const inventory = @import("../inventory.zig");
const rule = @import("cli_source").library_inventory_collect;
const InventoryEntry = @import("publication_abi").layouts.@"zig:publication_host".InventoryEntry;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Error = effects.Error;

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn collect(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const inventory.File {
    var failure: effects.Failure = .{};
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const scratch = arena.allocator();
    var directory: Directory = .{ .io = io, .allocator = scratch, .failure = &failure, .source = path };

    defer directory.deinit();

    const handle = &directory;
    var entries: StoreState = &.{ .paths = &.{}, .digests = &.{} };
    var host: StoreHost = .{ .store_0 = &entries };

    const outcome = rule.execute(&arena, &.{
        .directory = @ptrCast(&handle),
        .name = inventory.name,
        .running = true,
    }, &host) catch |err| return failure.unwrap(err);

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

pub fn digestEntry(handle: *const anyopaque, portable_path: []const u8) Error!*const InventoryEntry {
    const directory = effects.state(Directory, handle);
    const allocator = directory.allocator;
    const hash = inventory.digest(directory.io, directory.directory, directory.path) catch |err| return directory.failure.save(err);
    const hex = std.fmt.bytesToHex(hash, .lower);
    const owned_path = allocator.dupe(u8, portable_path) catch |err| return directory.failure.save(err);
    const owned_digest = allocator.dupe(u8, &hex) catch |err| return directory.failure.save(err);

    directory.inventory_view = .{ .path = owned_path, .digest = owned_digest };

    return &directory.inventory_view;
}
