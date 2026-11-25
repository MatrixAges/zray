const std = @import("std");
const Options = @import("options.zig").Options;
pub const driver = @import("watch/driver/storage.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var state = driver.State.init(io, allocator, options, environment, stdout, stderr);

    defer state.deinit();

    const handle = &state;

    @import("cli_watch").run.executeIn(allocator, @ptrCast(&handle)) catch |err| return if (err == error.WatchFailure) state.failure.? else err;
}
