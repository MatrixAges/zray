const std = @import("std");
const bundle = @import("bundle");
const reference = @import("zig_archive");

pub const embedded = reference.embedded;

pub fn zip(io: std.Io, directory: std.Io.Dir, archive: []const u8) !void {
    {
        const file = try directory.createFile(io, "zig.zip", .{});

        defer file.close(io);

        try file.writeStreamingAll(io, archive);
    }

    {
        const file = try directory.openFile(io, "zig.zip", .{});

        defer file.close(io);

        var buffer: [65536]u8 = undefined;
        var reader = file.reader(io, &buffer);

        try std.zip.extract(directory, &reader, .{});
    }

    try directory.deleteFile(io, "zig.zip");
}

pub fn tar(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, archive: []const u8) !void {
    var input: std.Io.Reader = .fixed(archive);
    var decompressed = try std.compress.xz.Decompress.init(&input, allocator, &.{});

    defer decompressed.deinit();

    try std.tar.extract(io, directory, &decompressed.reader, .{});

    var remaining: [65536]u8 = undefined;

    while (try decompressed.reader.readSliceShort(&remaining) != 0) {}
}

/// Unpacks the zxc standard sources and licenses into `directory`.
pub fn resources(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir) anyerror!void {
    var input: std.Io.Reader = .fixed(bundle.archive);
    const buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);

    defer allocator.free(buffer);

    var decompressed = std.compress.flate.Decompress.init(&input, .gzip, buffer);

    try std.tar.extract(io, directory, &decompressed.reader, .{});

    _ = try decompressed.reader.discardRemaining();
}

/// The official Zig archive: embedded by release builds, otherwise read from the build cache of the machine that
/// built zxc. Elsewhere a build without it needs `ZXC_ZIG`.
pub fn zigArchive(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    if (reference.embedded) return bundle.zig_archive;

    const path = try std.fs.path.resolve(allocator, &.{ reference.base, reference.path });

    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => error.ZxcZigRequired,
        else => err,
    };
}

pub fn hashMatches(bytes: []const u8, expected: []const u8) bool {
    var hash: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});

    return std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), expected);
}
