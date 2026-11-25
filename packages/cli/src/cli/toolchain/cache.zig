const std = @import("std");
const builtin = @import("builtin");
const rule = @import("cli_source").cache_root;

const Context = struct {
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    result: []const u8 = undefined,
    fn get(handle: *anyopaque) *Context {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn root(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]const u8 {
    var context: Context = .{ .allocator = allocator, .environment = environment };

    const status = try rule.executeValue(allocator, &.{
        .environment = @ptrCast(&context),
        .platform = switch (builtin.os.tag) {
            .windows => .Windows,
            .macos => .Mac,
            else => .Other,
        },
    });

    return switch (status) {
        .Ready => context.result,
        .InvalidZxcCacheDirectory => error.InvalidZxcCacheDirectory,
        .MissingUserCacheDirectory => error.MissingUserCacheDirectory,
        .InvalidUserCacheDirectory => error.InvalidUserCacheDirectory,
    };
}

pub fn get(handle: *anyopaque, key: []const u8) ?[]const u8 {
    return Context.get(handle).environment.get(key);
}

pub fn usePath(handle: *anyopaque, path: []const u8) void {
    Context.get(handle).result = path;
}

pub fn joinPath(handle: *anyopaque, base: []const u8, first: []const u8, second: ?[]const u8, third: ?[]const u8) error{OutOfMemory}!void {
    const context = Context.get(handle);
    const parts = [_][]const u8{ base, first, second orelse "", third orelse "" };
    const count: usize = if (third != null) 4 else if (second != null) 3 else 2;

    context.result = try std.fs.path.join(context.allocator, parts[0..count]);
}
