const std = @import("std");
const rules = @import("cli_source");
const columns = @import("zx").columns;
const Sha256 = std.crypto.hash.sha2.Sha256;
const constants = rules.library_publication_constants.@"zx.constants";
pub const name = constants.inventory_name;
pub const limit = constants.inventory_limit;
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
        if (std.mem.eql(u8, entry.path, name)) continue;

        const path = try allocator.dupe(u8, entry.path);

        makePortable(path);

        if (!valid(path, false)) return error.InvalidLibraryInventory;

        const hash = try digest(io, root, entry.path);

        try files.append(allocator, .{ .path = path, .sha256 = try allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
    }

    std.mem.sort(File, files.items, {}, lessThan);

    return files.toOwnedSlice(allocator);
}

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

pub fn valid(path: []const u8, native_only: bool) bool {
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return columns.invoke(rules.library_inventory_path.executeValue, memory.allocator(), &.{
        .path = path,
        .absolute = std.fs.path.isAbsolute(path),
        .native_only = native_only,
    }) catch unreachable;
}

pub fn makePortable(path: []u8) void {
    if (std.fs.path.sep == '\\') for (path) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
}

pub fn digest(io: std.Io, dir: std.Io.Dir, path: []const u8) ![Sha256.digest_length]u8 {
    const file = try dir.openFile(io, path, .{ .allow_directory = @import("builtin").os.tag != .windows });

    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash = Sha256.init(.{});

    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };

        hash.update(chunk);
        reader.interface.tossBuffered();
    }

    return hash.finalResult();
}

fn lessThan(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}
