const std = @import("std");
const interrupt = @import("../interrupt.zig");
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;
const constants = @import("cli_watch").constants.@"zx.constants";

pub fn interrupted(_: *const anyopaque) bool {
    return interrupt.requested();
}

pub fn hasBaseline(handle: *const anyopaque) bool {
    const self = State.get(handle);

    return self.last_failure != null or self.last_success != null;
}

pub fn lastStatus(handle: *const anyopaque) storage.Status {
    return State.get(handle).status;
}

pub fn delayPoll(handle: *const anyopaque) Error!void {
    return delay(handle, constants.poll_delay_ms);
}

pub fn delayRetry(handle: *const anyopaque) Error!void {
    return delay(handle, constants.retry_delay_ms);
}

fn delay(handle: *const anyopaque, milliseconds: u64) Error!void {
    const self = State.get(handle);

    std.Io.sleep(self.io, .fromMilliseconds(@intCast(milliseconds)), .awake) catch |err| return self.fail(err);
}

pub fn checkCanceled(handle: *const anyopaque) Error!void {
    if (interrupted(handle)) return State.get(handle).fail(error.Canceled);
}

pub fn pollApplication(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.application.poll(self.io, self.stderr) catch |err| return self.fail(err);
}

pub fn scanInputs(handle: *const anyopaque) Error!storage.Scan {
    const self = State.get(handle);
    const baseline = self.last_failure orelse self.last_success.?;

    const unchanged = baseline.poll(self.io, self.allocator) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

        const repeated = if (self.scan_error) |previous| previous == err else false;

        self.scan_error = err;

        return if (repeated) .RepeatedError else .NewError;
    };

    self.scan_error = null;

    return if (unchanged) .Unchanged else .Changed;
}

pub fn reportScanError(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stderr.print("zxc watch: input scan: {s}\n", .{@errorName(self.scan_error.?)}) catch |err| return self.fail(err);
    self.stderr.flush() catch |err| return self.fail(err);
}

pub fn clearScanError(handle: *const anyopaque) void {
    State.get(handle).scan_error = null;
}
