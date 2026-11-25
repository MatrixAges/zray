const std = @import("std");
const watch = @import("watch_inputs");
const effects = @import("effects.zig");
const Self = @This();

io: std.Io,
allocator: std.mem.Allocator,
snapshot_allocator: std.mem.Allocator,
inputs: *watch.Inputs,
failure: *effects.Failure,
snapshot: ?watch.Snapshot = null,
pub fn deinit(self: *Self) void {
    if (self.snapshot) |*value| value.deinit();
}

pub fn capture(handle: *anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);

    self.snapshot = self.inputs.observed(self.snapshot_allocator) catch |err| return self.failure.save(err);
}

pub fn verify(handle: *anyopaque) effects.Error!bool {
    const self = effects.borrow(Self, handle);

    return self.inputs.verify(self.io, self.allocator, self.snapshot.?) catch |err| return self.failure.save(err);
}

pub fn retain(handle: *anyopaque) void {
    const self = effects.borrow(Self, handle);

    if (self.inputs.retainPublished(self.snapshot.?)) self.snapshot = null;
}
