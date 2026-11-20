const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const File = struct { path: []const u8, sha256: []const u8, executable: bool };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    files: []const File,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

const constants = @import("package_cache").constants.@"zx.constants";
pub const maximum_archive: usize = constants.maximum_archive;
pub const maximum_unpacked: usize = constants.maximum_unpacked;
pub const maximum_entries: usize = constants.maximum_entries;
pub const Verified = struct { source: []const u8 };

pub fn verify(source: []const u8, expected: [32]u8) !Verified {
    if (source.len > maximum_archive) return error.PackageArchiveTooLarge;

    var digest: [32]u8 = undefined;

    Sha256.hash(source, &digest, .{});

    if (!std.mem.eql(u8, &digest, &expected)) return error.PackageArchiveChecksumMismatch;

    return .{ .source = source };
}

pub fn extract(io: std.Io, allocator: std.mem.Allocator, source: []const u8, expected: [32]u8, directory: std.Io.Dir) !Result {
    return unpack(io, allocator, try verify(source, expected), directory);
}

pub fn unpack(io: std.Io, allocator: std.mem.Allocator, verified: Verified, directory: std.Io.Dir) !Result {
    const unpacked = try @import("archive/decode.zig").decode(allocator, verified.source, maximum_unpacked, maximum_entries);

    defer allocator.free(unpacked);

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var input: std.Io.Reader = .fixed(unpacked);
    var names: [std.fs.max_path_bytes]u8 = undefined;
    var links: [std.fs.max_path_bytes]u8 = undefined;
    var iterator = std.tar.Iterator.init(&input, .{ .file_name_buffer = &names, .link_name_buffer = &links });

    var state: extraction.State = .{
        .io = io,
        .directory = directory,
        .allocator = arena.allocator(),
        .iterator = &iterator,
    };

    const status = @import("package_cache").unpack.executeValue(state.allocator, @ptrCast(&state)) catch |err| switch (err) {
        error.ArchiveHostFailure => return state.failure.?,
        else => |failure| return failure,
    };

    switch (status) {
        .Valid => {},
        inline else => |reason| return @field(anyerror, @tagName(reason)),
    }

    return .{ .arena = arena, .files = try state.files.toOwnedSlice(state.allocator) };
}

pub const extraction = @import("archive/extract/storage.zig");
