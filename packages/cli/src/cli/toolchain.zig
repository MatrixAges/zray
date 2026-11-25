const std = @import("std");
const builtin = @import("builtin");
const source = @import("cli_source");
pub const cache = @import("toolchain_cache");
pub const workflow = @import("toolchain/workflow/storage.zig");
pub const constants = source.toolchain_constants.@"zx.constants";
pub const Paths = struct { root: []const u8, executable: []const u8, library: []const u8, standard: []const u8 };

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) !Paths {
    const zig = environment.get(constants.zig_override);
    const windows = builtin.os.tag == .windows;
    var state: workflow.State = .{ .io = io, .allocator = allocator, .environment = environment, .override = zig };

    defer state.deinit();

    const outcome = source.resolve.executeValue(allocator, &.{
        .toolchain = @ptrCast(&state),
        .external = zig != null,
        .windows = windows,
    }) catch |err| return if (err == error.ToolchainHostFailure) state.failure.? else err;

    switch (outcome) {
        .Ready => {},
        .IncompleteToolchainCache => return error.IncompleteToolchainCache,
        .ZxcZigLibraryNotFound => return error.ZxcZigLibraryNotFound,
        .CorruptBundledToolchain => return error.CorruptBundledToolchain,
    }

    return .{
        .root = state.root,
        .executable = if (zig != null) state.executable else try std.fs.path.join(allocator, &.{ state.root, constants.zig_directory, if (windows) constants.windows_zig_executable else constants.zig_directory }),
        .library = if (zig != null) state.library else try std.fs.path.join(allocator, &.{ state.root, constants.zig_directory, constants.official_lib }),
        .standard = try std.fs.path.join(allocator, &.{ state.root, constants.standard_directory }),
    };
}
