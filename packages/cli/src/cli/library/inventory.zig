const std = @import("std");
const rules = @import("cli_source");
const Sha256 = std.crypto.hash.sha2.Sha256;
const constants = rules.library_publication_constants.@"zx.constants";
pub const name = constants.inventory_name;
pub const limit = constants.inventory_limit;
pub const File = struct { path: []const u8, sha256: []const u8 };
pub const Inventory = struct { format_version: u32, bundled_files: []const File = &.{}, managed_files: ?[]const File = null };
pub const collect = @import("inventory/collector.zig").collect;

pub fn read(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !?std.json.Parsed(Inventory) {
    const path = try std.fs.path.join(allocator, &.{ directory, name });

    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(Inventory, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });

    errdefer parsed.deinit();

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    if (!(rules.library_inventory_version.executeValue(memory.allocator(), parsed.value.format_version) catch unreachable)) return error.InvalidLibraryInventory;

    return parsed;
}

pub fn digest(io: std.Io, dir: std.Io.Dir, path: []const u8) ![Sha256.digest_length]u8 {
    const file = try dir.openFile(io, path, .{ .allow_directory = @import("builtin").os.tag != .windows });

    defer file.close(io);

    return @import("artifact_io").digestFile(io, file);
}
