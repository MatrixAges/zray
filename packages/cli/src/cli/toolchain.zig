const std = @import("std");
const builtin = @import("builtin");
const bundle = @import("bundle");
const source = @import("cli_source");
pub const cache = @import("toolchain_cache");
pub const workflow = @import("toolchain/workflow/storage.zig");
pub const constants = source.toolchain_constants.@"zx.constants";
pub const Paths = struct { root: []const u8, executable: []const u8, library: []const u8, standard: []const u8 };

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) !Paths {
    const zig = environment.get(constants.zig_override);
    const windows = builtin.os.tag == .windows;
    var state: workflow.State = .{ .io = io, .allocator = allocator };
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();
    defer state.deinit();

    const Entry = source.resolve;
    const Config = std.meta.Child(@FieldType(std.meta.Child(Entry.Input), "cache_config"));
    const config = cache.config(Config, environment);
    const resources = &state;

    const outcome = Entry.executeIn(scratch.allocator(), &.{
        .toolchain = @ptrCast(&resources),
        .cache_config = &config,
        .override = zig,
        .windows = windows,
        .expected_marker = if (zig != null) bundle.resources_digest else bundle.digest,
        .zip = bundle.zig_format == .zip,
        .zig_source_directory = bundle.zig_directory,
        .standard_archive = bundle.archive,
        .standard_digest = bundle.resources_digest,
        .zig_digest = bundle.zig_digest,
        .library_suffixes = &.{
            .official = constants.official_lib,
            .system = constants.system_lib,
            .sibling = constants.sibling_lib,
        },
    }, io) catch |err| return if (err == error.ToolchainHostFailure) state.failure.? else err;

    switch (outcome.status) {
        .Ready => {},
        .IncompleteToolchainCache => return error.IncompleteToolchainCache,
        .ZxcZigNotFound => return error.ZxcZigNotFound,
        .ZxcZigLibraryNotFound => return error.ZxcZigLibraryNotFound,
        .CorruptBundledToolchain => return error.CorruptBundledToolchain,
        .InvalidZxcCacheDirectory => return error.InvalidZxcCacheDirectory,
        .MissingUserCacheDirectory => return error.MissingUserCacheDirectory,
        .InvalidUserCacheDirectory => return error.InvalidUserCacheDirectory,
    }

    state.staging = null;

    const root = try allocator.dupe(u8, outcome.root.?);

    return .{
        .root = root,
        .executable = if (outcome.executable) |path|
            try allocator.dupeSentinel(u8, path, 0)
        else
            try std.fs.path.join(allocator, &.{ root, constants.zig_directory, if (windows) constants.windows_zig_executable else constants.zig_directory }),
        .library = if (outcome.library) |path|
            try allocator.dupe(u8, path)
        else
            try std.fs.path.join(allocator, &.{ root, constants.zig_directory, constants.official_lib }),
        .standard = try std.fs.path.join(allocator, &.{ root, constants.standard_directory }),
    };
}
