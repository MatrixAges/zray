const std = @import("std");
const builtin = @import("builtin");
const rule = @import("cli_source").cache_root;
const constants = @import("cli_source").toolchain_constants.@"zx.constants";

pub fn config(comptime Input: type, environment: *const std.process.Environ.Map) Input {
    const windows = builtin.os.tag == .windows;

    return .{
        .platform = switch (builtin.os.tag) {
            .windows => .Windows,
            .macos => .Mac,
            else => .Other,
        },
        .configured = environment.get(constants.cache_override),
        .xdg = environment.get(constants.xdg_cache),
        .home = environment.get(if (windows) constants.windows_cache else constants.user_home),
    };
}

pub fn root(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]const u8 {
    const input = config(std.meta.Child(rule.Input), environment);
    const outcome = try rule.executeIn(allocator, &input);

    return switch (outcome.status) {
        .Ready => outcome.path.?,
        .InvalidZxcCacheDirectory => error.InvalidZxcCacheDirectory,
        .MissingUserCacheDirectory => error.MissingUserCacheDirectory,
        .InvalidUserCacheDirectory => error.InvalidUserCacheDirectory,
    };
}
