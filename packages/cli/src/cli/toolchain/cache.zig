const std = @import("std");
const builtin = @import("builtin");
const rule = @import("cli_source").cache_root;
const constants = @import("cli_source").toolchain_constants.@"zx.constants";

pub fn root(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]const u8 {
    const windows = builtin.os.tag == .windows;

    const outcome = try rule.executeIn(allocator, &.{
        .platform = switch (builtin.os.tag) {
            .windows => .Windows,
            .macos => .Mac,
            else => .Other,
        },
        .configured = environment.get(constants.cache_override),
        .xdg = environment.get(constants.xdg_cache),
        .home = environment.get(if (windows) constants.windows_cache else constants.user_home),
    });

    return switch (outcome.status) {
        .Ready => outcome.path.?,
        .InvalidZxcCacheDirectory => error.InvalidZxcCacheDirectory,
        .MissingUserCacheDirectory => error.MissingUserCacheDirectory,
        .InvalidUserCacheDirectory => error.InvalidUserCacheDirectory,
    };
}
