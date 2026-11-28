const std = @import("std");
const watch = @import("watch_inputs");
const effects = @import("effects.zig");
const Self = @This();
const memory = @import("zx").memory;

io: std.Io,
allocator: std.mem.Allocator,
snapshot_allocator: std.mem.Allocator,
inputs: *watch.Inputs,
failure: *effects.Failure,
snapshot: ?watch.Snapshot = null,
observed: memory.TextColumn = undefined,
pub fn deinit(self: *Self) void {
    if (self.snapshot) |*value| value.deinit();
}

pub fn checkPublishedTarget(allocator: std.mem.Allocator, handle: *const anyopaque, path: []const u8) effects.Error![]const u8 {
    const self = effects.state(Self, handle);

    return @import("../watch/output.zig").check(self.io, allocator, self.inputs, path) catch |err| self.failure.save(err);
}

pub fn capture(handle: *const anyopaque) effects.Error!u64 {
    const self = effects.state(Self, handle);

    self.snapshot = self.inputs.observed(self.snapshot_allocator) catch |err| return self.failure.save(err);
    self.observed = memory.borrowTextColumn("path", self.snapshot.?.entries);

    return self.observed.count;
}

pub fn verify(handle: *const anyopaque, versioned: bool) effects.Error!bool {
    const self = effects.state(Self, handle);
    const captured = &self.snapshot.?;

    const result = if (versioned)
        captured.verifyVersions(self.io, self.allocator)

    else
        captured.unchanged(self.io, self.allocator);

    return result catch |err| self.failure.save(err);
}

pub fn retain(handle: *const anyopaque) void {
    const self = effects.state(Self, handle);

    std.debug.assert(self.inputs.published == null);

    self.inputs.published = self.snapshot.?;
    self.snapshot = null;
}
