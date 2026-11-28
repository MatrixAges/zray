const std = @import("std");
const Options = @import("options.zig").Options;
pub const driver = @import("watch/driver/storage.zig");
const rule = @import("cli_source").run;
const Store0 = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Store1 = std.meta.Child(@FieldType(rule.zx_pending, "store_1"));

const StoreHost = struct {
    store_0: *Store0,
    store_1: *Store1,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
        if (pending.store_1) |next| self.store_1.* = next;
    }
};

fn initEmptyStore(comptime Pointer: type) std.meta.Child(Pointer) {
    const T = std.meta.Child(Pointer);

    if (comptime @hasField(T, "has_last")) {
        return .{ .has_last = false, .last = "" };
    }

    return .{ .has_success = false, .has_failure = false };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var state = driver.State.init(io, allocator, options, environment, stdout, stderr);

    defer state.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var store_0_value = initEmptyStore(Store0);
    var store_1_value = initEmptyStore(Store1);
    var store_0: Store0 = &store_0_value;
    var store_1: Store1 = &store_1_value;
    var host: StoreHost = .{ .store_0 = &store_0, .store_1 = &store_1 };
    const handle = &state;

    const canceled = rule.execute(&arena, &.{
        .watch = @ptrCast(&handle),
        .cache = options.cache,
        .run_application = options.run,
        .windows = @import("builtin").os.tag == .windows,
        .input_path = options.input,
        .output_path = options.output.?,
    }, &host) catch |err| return if (err == error.WatchFailure) state.failure.? else err;

    if (canceled) return error.Canceled;
}
