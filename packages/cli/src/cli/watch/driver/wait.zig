const std = @import("std");
const interrupt = @import("../interrupt.zig");
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;

pub fn interrupted(_: *const anyopaque) bool {
    return interrupt.requested();
}

pub fn delay(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromMilliseconds(@intCast(milliseconds)), .awake);
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
