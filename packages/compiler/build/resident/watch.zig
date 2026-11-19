const std = @import("std");
const protocol = @import("compiler").resident_protocol;
const Resident = @import("state.zig");
const Self = @This();
const active = std.math.maxInt(u64);
const stopping = active - 1;

io: std.Io,
path: []const u8,
resident: *Resident,
state: std.atomic.Value(u64) = .init(active),
/// Only the serving thread enters or finishes a request. The watcher may claim an unchanged idle state.
pub fn begin(self: *Self) bool {
    const last = self.state.load(.acquire);

    return last != stopping and self.state.cmpxchgStrong(last, active, .acq_rel, .acquire) == null;
}

pub fn finish(self: *Self) void {
    self.state.store(self.now(), .release);
}

pub fn run(self: *Self) void {
    while (true) {
        self.io.sleep(.fromSeconds(@intCast(protocol.settings.check_interval_seconds)), .awake) catch {};

        const last = self.state.load(.acquire);

        if (last == active or !protocol.expired(last, self.now())) continue;
        if (self.state.cmpxchgStrong(last, stopping, .acq_rel, .acquire) != null) continue;

        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.resident.persist();
        std.process.exit(0);
    }
}

fn now(self: *const Self) u64 {
    return @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds);
}
