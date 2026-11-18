const std = @import("std");
const Options = @This();
pub const usage = "zxc pkg install [pkg.yaml] [--index index.json] [--offline] [--frozen-lockfile]\n";

path: []const u8 = "pkg.yaml",
index: ?[]const u8 = null,
offline: bool = false,
frozen: bool = false,
pub fn parse(args: []const []const u8) !Options {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const state = @import("cli_arguments").package_install.executeValue(empty.allocator(), args) catch unreachable;

    if (!state.valid) return error.InvalidArguments;

    return .{
        .path = state.path orelse (Options{}).path,
        .index = state.index,
        .offline = state.offline,
        .frozen = state.frozen,
    };
}
