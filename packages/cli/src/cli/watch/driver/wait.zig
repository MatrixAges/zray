const std = @import("std");
const interrupt = @import("../interrupt.zig");
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;
const constants = @import("cli_source").watch_constants.@"zx.constants";

pub fn interrupted(_: *const anyopaque) bool {
    return interrupt.requested();
}

pub fn delay(handle: *const anyopaque, interval: @import("cli_abi").native.@"zig:watch_host".Delay) Error!void {
    const self = State.get(handle);

    const milliseconds = switch (interval) {
        .Poll => constants.poll_delay_ms,
        .Retry => constants.retry_delay_ms,
    };

    std.Io.sleep(self.io, .fromMilliseconds(@intCast(milliseconds)), .awake) catch |err| return self.fail(err);
}

pub fn scanInputs(handle: *const anyopaque, slot: storage.SnapshotSlot) Error!*const storage.ScanResult {
    const self = State.get(handle);
    const baseline = &self.snapshotSlot(slot).*.?;

    const unchanged = baseline.poll(self.io, self.allocator) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

        self.scan = .{ .changed = false, .error_name = @errorName(err) };

        return &self.scan;
    };

    self.scan = .{ .changed = !unchanged, .error_name = null };

    return &self.scan;
}
