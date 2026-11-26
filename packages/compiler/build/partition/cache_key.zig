const std = @import("std");
const rules = @import("partition_rules");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Digest = [Blake3.digest_length]u8;
const Encoded = @TypeOf(std.fmt.bytesToHex(@as(Digest, @splat(0)), .lower));
const buffer_size = 16 * 1024;
const Listed = @import("file_manifest").Listed;
const Members = @FieldType(std.meta.Child(rules.partition_cache_selection.Output), "members");

pub const Shared = struct {
    buffer: [buffer_size]u8 = undefined,
    hasher: Blake3 = undefined,
    pub fn init(self: *Shared) void {
        self.hasher = Blake3.init(.{});
    }

    pub fn prefix(self: *Shared, allocator: std.mem.Allocator, executable: []const u8, stat: Io.File.Stat, arguments: []const []const u8, types: u64, signatures: u64) !void {
        var scratch = std.heap.ArenaAllocator.init(allocator);

        defer scratch.deinit();

        const rule = rules.partition_cache_prefix;

        const encoded = try rule.executeIn(scratch.allocator(), &.{
            .executable = executable,
            .size = stat.size,
            .modified = @bitCast(@as(i64, @truncate(stat.mtime.nanoseconds))),
            .arguments = arguments,
            .types = types,
            .signatures = signatures,
        });

        self.hasher.update(encoded);
    }

    pub fn state(self: *const Shared) Blake3 {
        return self.hasher;
    }
    pub fn input(self: *Shared, io: Io, allocator: std.mem.Allocator, path: []const u8) !void {
        try inputPath(io, allocator, &self.hasher, &self.buffer, path);
    }
};

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

pub const Partitions = struct {
    source: Blake3,
    names: []Encoded,
    hex: [][]const u8,
    pub fn init(allocator: std.mem.Allocator, source: Blake3, count: usize) !Partitions {
        return .{
            .source = source,
            .names = try allocator.alloc(Encoded, count),
            .hex = try allocator.alloc([]const u8, count),
        };
    }
    pub fn hash(self: *Partitions, allocator: std.mem.Allocator, row: usize, manifest: Listed, group: Members) void {
        var digest: Digest = undefined;

        members(allocator, self.source, manifest, group, &digest);

        self.names[row] = std.fmt.bytesToHex(digest, .lower);
        self.hex[row] = &self.names[row];
    }
};

fn members(allocator: std.mem.Allocator, shared: Blake3, manifest: Listed, group: Members, digest: *Digest) void {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const encoded = rules.partition_cache_members.executeIn(scratch.allocator(), &.{
        .paths = manifest.paths,
        .hashes = manifest.hashes,
        .members = group,
    }) catch unreachable;

    var hasher = shared;

    hasher.update(encoded);
    hasher.final(digest);
}
