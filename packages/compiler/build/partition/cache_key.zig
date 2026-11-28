const std = @import("std");
const rules = @import("partition_rules");
const native = @import("partition_abi").native.@"zig:partition_host";
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Digest = [Blake3.digest_length]u8;
const buffer_size = 16 * 1024;
pub const initial_hash = Blake3.init(.{});

pub fn extendPartitionHash(allocator: std.mem.Allocator, prefix: native.PartitionHash, encoded: []const u8) !native.PartitionHash {
    const initial: *const Blake3 = @ptrCast(@alignCast(prefix));
    const hasher = try allocator.create(Blake3);

    hasher.* = initial.*;

    hasher.update(encoded);

    return @ptrCast(hasher);
}

pub fn hashExternalInput(allocator: std.mem.Allocator, io: Io, prefix: native.PartitionHash, path: []const u8) !native.hashExternalInput.Output {
    const previous: *const Blake3 = @ptrCast(@alignCast(prefix));
    const next = try allocator.create(Blake3);
    var buffer: [buffer_size]u8 = undefined;
    next.* = previous.*;

    try inputPath(io, std.heap.smp_allocator, next, &buffer, path);

    return @ptrCast(next);
}

fn inputPath(io: Io, workspace: std.mem.Allocator, hasher: *Blake3, buffer: []u8, path: []const u8) !void {
    const cwd = Io.Dir.cwd();

    if ((try cwd.statFile(io, path, .{})).kind == .file) return file(io, workspace, cwd, hasher, buffer, path);

    var directory = try cwd.openDir(io, path, .{ .iterate = true });

    defer directory.close(io);

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const allocator = scratch.allocator();
    var walker = try directory.walk(allocator);

    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;

    while (try walker.next(io)) |entry| if (entry.kind == .file) try paths.append(allocator, try allocator.dupe(u8, entry.path));

    const ordered = try rules.partition_cache_external_order.executeValue(allocator, paths.items);

    try external(allocator, hasher, path, null);
    for (ordered) |child| try file(io, allocator, directory, hasher, buffer, child);
}

fn file(io: Io, allocator: std.mem.Allocator, directory: Io.Dir, hasher: *Blake3, buffer: []u8, path: []const u8) !void {
    const handle = try directory.openFile(io, path, .{});

    defer handle.close(io);

    const size = try handle.length(io);

    try external(allocator, hasher, path, size);

    var offset: u64 = 0;

    while (offset < size) {
        const length: usize = @intCast(@min(buffer.len, size - offset));
        const block = buffer[0..length];

        if (try handle.readPositionalAll(io, block, offset) != length) return error.FileChanged;

        hasher.update(block);

        offset += length;
    }

    if (try handle.length(io) != size) return error.FileChanged;
}

fn external(allocator: std.mem.Allocator, hasher: *Blake3, path: []const u8, size: ?u64) !void {
    var buffer: [512]u8 = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());

    defer scratch.deinit();

    const encoded = try rules.partition_cache_external.executeIn(scratch.allocator(), &.{ .path = path, .size = size });

    hasher.update(encoded);
}

pub fn digestPartitionKey(allocator: std.mem.Allocator, prefix: native.PartitionHash, encoded: []const u8) ![]const u8 {
    const source: *const Blake3 = @ptrCast(@alignCast(prefix));
    var hasher = source.*;
    var digest: Digest = undefined;

    hasher.update(encoded);
    hasher.final(&digest);

    const hex = try allocator.create(@TypeOf(std.fmt.bytesToHex(digest, .lower)));

    hex.* = std.fmt.bytesToHex(digest, .lower);

    return hex;
}
