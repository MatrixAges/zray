const std = @import("std");
const rules = @import("partition_rules");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Digest = [Blake3.digest_length]u8;
const Encoded = @TypeOf(std.fmt.bytesToHex(@as(Digest, @splat(0)), .lower));
const HashWriter = Io.Writer.Hashing(Blake3);
const buffer_size = 16 * 1024;
const Listed = @import("file_manifest.zig").Listed;
const Members = @FieldType(std.meta.Child(rules.partition_cache_selection.Output), "members");

pub const Shared = struct {
    buffer: [buffer_size]u8 = undefined,
    writer: HashWriter = undefined,
    pub fn init(self: *Shared) void {
        self.writer = .init(&self.buffer);
    }

    pub fn prefix(self: *Shared, executable: []const u8, stat: Io.File.Stat, arguments: []const []const u8, types: u64, signatures: u64) void {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const rule = rules.partition_cache_prefix;

        rule.executeValue(empty.allocator(), &.{
            .out = @ptrCast(&self.writer.writer),
            .executable = executable,
            .size = stat.size,
            .modified = @bitCast(@as(i64, @truncate(stat.mtime.nanoseconds))),
            .arguments = arguments,
            .types = types,
            .signatures = signatures,
        }) catch unreachable;
    }

    pub fn state(self: *Shared) Blake3 {
        self.writer.writer.flush() catch unreachable;

        return self.writer.hasher;
    }
    pub fn input(self: *Shared, io: Io, allocator: std.mem.Allocator, path: []const u8) !void {
        try inputPath(io, allocator, &self.writer, path);
    }
};

fn inputPath(io: Io, workspace: std.mem.Allocator, hash: *HashWriter, path: []const u8) !void {
    const cwd = Io.Dir.cwd();

    if ((try cwd.statFile(io, path, .{})).kind == .file) return file(io, cwd, hash, path);

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

    external(hash, path, null);

    for (ordered) |child| try file(io, directory, hash, child);
}

fn file(io: Io, directory: Io.Dir, hash: *HashWriter, path: []const u8) !void {
    const handle = try directory.openFile(io, path, .{});

    defer handle.close(io);

    const size = try handle.length(io);

    external(hash, path, size);
    hash.writer.flush() catch unreachable;

    var offset: u64 = 0;

    while (offset < size) {
        const length: usize = @intCast(@min(hash.writer.buffer.len, size - offset));
        const block = hash.writer.buffer[0..length];

        if (try handle.readPositionalAll(io, block, offset) != length) return error.FileChanged;

        hash.hasher.update(block);

        offset += length;
    }

    if (try handle.length(io) != size) return error.FileChanged;
}

fn external(hash: *HashWriter, path: []const u8, size: ?u64) void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const rule = rules.partition_cache_external;

    rule.executeValue(empty.allocator(), &.{ .out = @ptrCast(&hash.writer), .path = path, .size = size }) catch unreachable;
}

pub fn partitions(allocator: std.mem.Allocator, shared: Blake3, manifest: Listed, ordered: Members, offsets: []const u64) ![]const []const u8 {
    const names = try allocator.alloc(Encoded, offsets.len - 1);
    const hex = try allocator.alloc([]const u8, names.len);

    for (names, hex, offsets[0..names.len], offsets[1..]) |*name, *key, start, end| {
        var digest: Digest = undefined;

        members(shared, manifest, ordered[@intCast(start)..@intCast(end)], &digest);

        name.* = std.fmt.bytesToHex(digest, .lower);
        key.* = name;
    }

    return hex;
}

fn members(shared: Blake3, manifest: Listed, group: Members, digest: *Digest) void {
    var buffer: [1024]u8 = undefined;
    var stream: HashWriter = .initHasher(shared, &buffer);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const rule = rules.partition_cache_members;

    rule.executeValue(empty.allocator(), &.{
        .out = @ptrCast(&stream.writer),
        .paths = manifest.paths,
        .hashes = manifest.hashes,
        .members = group,
    }) catch unreachable;

    stream.writer.flush() catch unreachable;
    stream.hasher.final(digest);
}
