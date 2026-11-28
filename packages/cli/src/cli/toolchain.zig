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
    var state: workflow.State = .{ .io = io, .allocator = allocator, .environment = environment };

    defer state.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const outcome = source.resolve.executeIn(scratch.allocator(), &.{
        .toolchain = @ptrCast(&state),
        .override = zig,
        .windows = windows,
        .expected_marker = if (zig != null) bundle.resources_digest else bundle.digest,
        .zip = bundle.zig_format == .zip,
        .standard_archive = bundle.archive,
        .standard_digest = bundle.resources_digest,
        .zig_digest = bundle.zig_digest,
        .library_suffixes = &.{
            .official = constants.official_lib,
            .system = constants.system_lib,
            .sibling = constants.sibling_lib,
        },
    }) catch |err| return if (err == error.ToolchainHostFailure) state.failure.? else err;

    switch (outcome.status) {
        .Ready => {},
        .IncompleteToolchainCache => return error.IncompleteToolchainCache,
        .ZxcZigLibraryNotFound => return error.ZxcZigLibraryNotFound,
        .CorruptBundledToolchain => return error.CorruptBundledToolchain,
    }

    return .{
        .root = state.root,
        .executable = outcome.executable orelse try std.fs.path.join(allocator, &.{ state.root, constants.zig_directory, if (windows) constants.windows_zig_executable else constants.zig_directory }),
        .library = outcome.library orelse try std.fs.path.join(allocator, &.{ state.root, constants.zig_directory, constants.official_lib }),
        .standard = try std.fs.path.join(allocator, &.{ state.root, constants.standard_directory }),
    };
}
