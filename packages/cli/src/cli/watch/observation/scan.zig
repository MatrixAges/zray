const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const reader = @import("read.zig");
const storage = @import("storage.zig");
const Error = storage.Error;
const rule = @import("cli_source").scan;

const Context = struct {
    entries: []Snapshot.Entry,
    io: std.Io,
    scratch: std.heap.ArenaAllocator,
    started: i96 = 0,
    verified_file: ?Snapshot.VerifiedFile = null,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return storage.context(Context, handle);
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

pub fn scan(snapshot: Snapshot, io: std.Io, allocator: std.mem.Allocator, versioned: bool, reuse_versions: bool) !bool {
    var context: Context = .{ .entries = snapshot.entries, .io = io, .scratch = .init(allocator) };

    defer context.scratch.deinit();

    const handle = &context;

    return rule.executeValue(allocator, &.{
        .scan = @ptrCast(&handle),
        .count = snapshot.entries.len,
        .consistent = snapshot.consistent,
        .versioned = versioned,
        .reuse_versions = reuse_versions,
    }) catch |err| if (err == error.ObservationFailure) context.failure.? else err;
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
    _ = self.scratch.reset(.retain_capacity);

    var observation = reader.Context{
        .io = self.io,
        .allocator = self.scratch.allocator(),
        .path = entry.path,
        .started = self.started,
        .save_version = versioned,
    };

    reader.observe(&observation, entry.directory_entries) catch |err| return self.fail(err);

    self.verified_file = observation.verified_file;

    return Snapshot.sameState(&entry.state, &observation.result);
}

pub fn acceptVersion(handle: *const anyopaque, index: u64) void {
    const self = Context.get(handle);

    self.entries[@intCast(index)].verified_file = self.verified_file;
}
