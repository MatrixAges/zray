const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const reader = @import("read.zig");
const Error = @import("storage.zig").Error;
const rule = @import("watch_observation").scan;

const Context = struct {
    entries: []Snapshot.Entry,
    io: std.Io,
    scratch: std.heap.ArenaAllocator,
    started: i96 = 0,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

pub fn scan(snapshot: Snapshot, io: std.Io, allocator: std.mem.Allocator, versioned: bool, reuse_versions: bool) !bool {
    var context: Context = .{ .entries = snapshot.entries, .io = io, .scratch = .init(allocator) };

    defer context.scratch.deinit();

    return rule.executeValue(allocator, &.{
        .scan = @ptrCast(&context),
        .consistent = snapshot.consistent,
        .versioned = versioned,
        .reuse_versions = reuse_versions,
    }) catch |err| if (err == error.ObservationFailure) context.failure.? else err;
}

pub fn scanCount(handle: *const anyopaque) u64 {
    return Context.get(handle).entries.len;
}

pub fn startVersions(handle: *const anyopaque) void {
    const self = Context.get(handle);

    self.started = std.Io.Timestamp.now(self.io, .real).nanoseconds;
}

pub fn versionMatches(handle: *const anyopaque, index: u64) Error!bool {
    const self = Context.get(handle);

    return self.entries[@intCast(index)].stillMatches(self.io) catch |err| self.fail(err);
}

pub fn readRow(handle: *const anyopaque, index: u64, versioned: bool) Error!bool {
    const self = Context.get(handle);
    const entry = &self.entries[@intCast(index)];

    var observation = reader.Context{
        .io = self.io,
        .allocator = self.scratch.allocator(),
        .path = entry.path,
        .started = self.started,
        .save_version = versioned,
    };

    reader.observe(&observation, entry.directory_entries) catch |err| return self.fail(err);

    if (!Snapshot.sameState(&entry.state, &observation.result)) return false;
    if (versioned) entry.verified_file = observation.verified_file;

    _ = self.scratch.reset(.retain_capacity);

    return true;
}
