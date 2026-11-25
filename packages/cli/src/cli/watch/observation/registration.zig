const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const reader = @import("read.zig");
const storage = @import("storage.zig");
const Error = storage.Error;
const source = @import("watch_observation");

const Slot = struct {
    path: []const u8,
    value: *Inputs.Observation,
    existing: bool,
};

const Context = struct {
    inputs: *Inputs,
    io: std.Io,
    path: []const u8,
    bytes: []const u8 = &.{},
    slot: Slot = undefined,
    flags: storage.Slot = undefined,
    current: Snapshot.State = undefined,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return storage.context(Context, handle);
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

fn lookup(inputs: *Inputs, path: []const u8) !Slot {
    const allocator = inputs.arena.allocator();
    const normalized = try std.fs.path.resolve(allocator, &.{ inputs.cwd, path });

    errdefer allocator.free(normalized);

    const entry = try inputs.entries.getOrPut(allocator, normalized);

    if (entry.found_existing) allocator.free(normalized);

    return .{ .path = entry.key_ptr.*, .value = entry.value_ptr, .existing = entry.found_existing };
}

pub const Addition = struct { entry: *Inputs.Observation, inserted: bool };

pub fn add(inputs: *Inputs, io: std.Io, path: []const u8, directory_entries: bool) !Addition {
    var context: Context = .{ .io = io, .inputs = inputs, .path = path };
    const handle = &context;

    const admission = source.add.executeIn(inputs.arena.allocator(), &.{
        .registration = @ptrCast(&handle),
        .directory_entries = directory_entries,
    }) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;

    return .{ .entry = context.slot.value, .inserted = admission == .New };
}

pub fn record(inputs: *Inputs, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var context: Context = .{ .io = io, .inputs = inputs, .path = path, .bytes = bytes };
    const handle = &context;

    source.record.executeIn(inputs.arena.allocator(), @ptrCast(&handle)) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;
}

pub fn openRegistration(handle: *const anyopaque) Error!*const storage.Slot {
    const self = Context.get(handle);

    self.slot = if (self.inputs.entries.getEntry(self.path)) |entry|
        .{ .path = entry.key_ptr.*, .value = entry.value_ptr, .existing = true }

    else
        lookup(self.inputs, self.path) catch |err| return self.fail(err);

    const slot = self.slot;

    self.flags = .{
        .existing = slot.existing,
        .consumed = slot.existing and slot.value.consumed,
        .directory_entries = slot.existing and slot.value.directory_entries,
    };

    return &self.flags;
}

pub fn reusePrior(handle: *const anyopaque) storage.Reuse {
    const self = Context.get(handle);
    const previous = self.inputs.previous orelse return .Unavailable;
    const prior = previous.find(self.slot.path) orelse return .Unavailable;

    const matched = prior.stillMatches(self.io) catch |err| {
        self.failure = err;

        return .Failed;
    };

    if (!matched) return .Unavailable;

    self.current = prior.state;

    return .Read;
}

pub fn readCurrent(handle: *const anyopaque, directory_entries: bool) bool {
    const self = Context.get(handle);

    self.current = Snapshot.readWithDirectoryEntries(self.io, self.inputs.arena.allocator(), self.slot.path, directory_entries) catch |err| {
        self.failure = err;

        return false;
    };

    return true;
}

pub fn comparePrevious(handle: *const anyopaque) Error!bool {
    const self = Context.get(handle);
    var scratch = std.heap.ArenaAllocator.init(self.inputs.arena.child_allocator);

    defer scratch.deinit();

    const entry = self.slot.value;
    const prior = Snapshot.readWithDirectoryEntries(self.io, scratch.allocator(), self.slot.path, entry.directory_entries) catch |err| return self.fail(err);

    return self.inputs.consistent and Snapshot.sameState(&entry.state, &prior);
}

pub fn recordFile(handle: *const anyopaque) bool {
    const self = Context.get(handle);

    const physical = reader.physicalPath(self.io, self.inputs.arena.allocator(), self.slot.path) catch |err| {
        self.failure = err;

        return false;
    };

    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(self.bytes, &digest, .{});

    self.current = .{ .file = .{ .digest = digest, .physical_path = physical } };

    return true;
}

pub fn compareRecorded(handle: *const anyopaque) bool {
    const self = Context.get(handle);

    return self.inputs.consistent and Snapshot.sameState(&self.slot.value.state, &self.current);
}

pub fn publishObservation(handle: *const anyopaque, directory_entries: bool, consumed: bool, consistent: bool) Error!void {
    const self = Context.get(handle);

    self.inputs.consistent = self.inputs.consistent and consistent;

    self.slot.value.* = .{
        .state = if (self.failure) |err| .{ .failed = err } else self.current,
        .directory_entries = directory_entries,
        .consumed = consumed,
        .backend_preloaded = self.slot.existing and self.slot.value.backend_preloaded,
    };

    if (self.failure != null) return error.ObservationFailure;
}
