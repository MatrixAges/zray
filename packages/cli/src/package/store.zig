const std = @import("std");
const pkgs = @import("pkgs");
pub const archive = @import("archive.zig");
pub const receipt = @import("store/receipt.zig");
pub const cache = @import("store/cache/storage.zig");
pub const paths = @import("archive/path.zig");
pub const constants = @import("package_cache").constants.@"zx.constants";

pub fn prepare(io: std.Io, allocator: std.mem.Allocator, release: pkgs.Index.Release, source_base: []const u8, cache_root: []const u8, offline: bool) ![]u8 {
    if (!std.fs.path.isAbsolute(cache_root)) return error.InvalidPackageCacheDirectory;

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;

    if (release.sha256.len != constants.digest_width) return error.InvalidArchiveDigest;

    _ = try std.fmt.hexToBytes(&digest, release.sha256);

    const hex = std.fmt.bytesToHex(digest, .lower);
    const root = try std.fs.path.join(temporary, &.{ cache_root, constants.cache_directory, constants.cache_version });
    const destination = try std.fs.path.join(temporary, &.{ root, constants.content_directory, &hex });
    const package = try std.fs.path.join(temporary, &.{ destination, constants.package_directory });

    var state: cache.State = .{
        .io = io,
        .allocator = allocator,
        .temporary = temporary,
        .source = release.archive,
        .source_base = source_base,
        .root = root,
        .destination = destination,
        .digest = digest,
        .hex = &hex,
    };

    defer state.deinit();

    const status = @import("package_cache").prepare.executeValue(allocator, &.{
        .cache = @ptrCast(&state),
        .offline = offline,
    }) catch |err| switch (err) {
        error.PackageCacheFailure => return state.failure.?,
        else => |failure| return failure,
    };

    return switch (status) {
        .Ready => allocator.dupe(u8, package),
        inline else => |reason| @field(anyerror, @tagName(reason)),
    };
}
