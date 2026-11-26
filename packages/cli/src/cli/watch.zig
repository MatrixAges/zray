const std = @import("std");
const Options = @import("options.zig").Options;
pub const driver = @import("watch/driver/storage.zig");
const rule = @import("cli_source").run;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var state = driver.State.init(io, allocator, options, environment, stdout, stderr);

    defer state.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var diagnostics_value: std.meta.Child(StoreState) = .{ .has_last = false, .last = "" };
    var diagnostics: StoreState = &diagnostics_value;
    var host: StoreHost = .{ .store_0 = &diagnostics };
    const handle = &state;

    rule.execute(&arena, &.{
        .watch = @ptrCast(&handle),
        .cache = options.cache,
        .run_application = options.run,
    }, &host) catch |err| return if (err == error.WatchFailure) state.failure.? else err;
}
