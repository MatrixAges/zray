const std = @import("std");
const rules = @import("cli_source");
pub const File = struct { path: []const u8, sha256: []const u8 };
pub const Inventory = struct { format_version: u32, bundled_files: []const File = &.{}, managed_files: ?[]const File = null };

pub fn collect(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) ![]const File {
    var root = try std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true });

    defer root.close(io);

    var walker = try root.walk(allocator);

    defer walker.deinit();

    var files: std.ArrayList(File) = .empty;

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.InvalidLibraryInventory;
        if (std.mem.eql(u8, entry.path, "library.json")) continue;

        const path = try allocator.dupe(u8, entry.path);

        if (std.fs.path.sep == '\\') for (path) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };

        if (!valid(path, false)) return error.InvalidLibraryInventory;

        const bytes = try root.readFileAlloc(io, entry.path, allocator, .unlimited);

        defer allocator.free(bytes);

        var digest: [32]u8 = undefined;

        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

        try files.append(allocator, .{ .path = path, .sha256 = try allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) });
    }

    std.mem.sort(File, files.items, {}, lessThan);

    return files.toOwnedSlice(allocator);
}

pub fn read(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !?std.json.Parsed(Inventory) {
    const path = try std.fs.path.join(allocator, &.{ directory, "library.json" });

    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
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

pub fn valid(path: []const u8, native_only: bool) bool {
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return rules.library_inventory_path.executeValue(memory.allocator(), &.{
        .path = path,
        .absolute = std.fs.path.isAbsolute(path),
        .native_only = native_only,
    }) catch unreachable;
}

fn lessThan(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}
