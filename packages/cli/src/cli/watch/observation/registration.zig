const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
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
    current: Snapshot.State = undefined,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

fn lookup(inputs: *Inputs, path: []const u8) !Slot {
    const allocator = inputs.arena.allocator();
    const normalized = try std.fs.path.resolve(allocator, &.{ inputs.cwd, path });
    const entry = try inputs.entries.getOrPut(allocator, normalized);

    if (entry.found_existing) allocator.free(normalized);

    return .{ .path = entry.key_ptr.*, .value = entry.value_ptr, .existing = entry.found_existing };
}

pub fn add(inputs: *Inputs, io: std.Io, path: []const u8, directory_entries: bool) !void {
    var context: Context = .{ .io = io, .inputs = inputs, .path = path };

    _ = source.add.executeValue(inputs.arena.allocator(), &.{
        .registration = @ptrCast(&context),
        .directory_entries = directory_entries,
    }) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;
}

pub fn record(inputs: *Inputs, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var context: Context = .{ .io = io, .inputs = inputs, .path = path, .bytes = bytes };

    source.record.executeValue(inputs.arena.allocator(), @ptrCast(&context)) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;
}

pub fn admit(handle: *const anyopaque, directory_entries: bool) Error!storage.Admission {
    const self = Context.get(handle);

    const slot: Slot = if (self.inputs.entries.getPtr(self.path)) |existing|
        .{ .path = self.path, .value = existing, .existing = true }

    else
        lookup(self.inputs, self.path) catch |err| return self.fail(err);

    self.slot = slot;

    if (!slot.existing) return .New;

    return if (!directory_entries or slot.value.directory_entries) .Unchanged else .Upgrade;
}

pub fn reusePrior(handle: *const anyopaque) Error!bool {
    const self = Context.get(handle);
    const previous = self.inputs.previous orelse return false;
    const prior = previous.find(self.slot.path) orelse return false;

    const matched = prior.stillMatches(self.io) catch |err| {
        self.slot.value.* = .{ .state = .{ .failed = err } };

        return self.fail(err);
    };

    if (matched) self.slot.value.* = .{ .state = prior.state };

    return matched;
}

pub fn readCurrent(handle: *const anyopaque, directory_entries: bool) Error!void {
    const self = Context.get(handle);

    self.current = Snapshot.readWithDirectoryEntries(self.io, self.inputs.arena.allocator(), self.slot.path, directory_entries) catch |err| {
        if (self.slot.existing) self.inputs.consistent = false;

        self.slot.value.* = .{ .state = .{ .failed = err }, .directory_entries = directory_entries };

        return self.fail(err);
    };
}

pub fn comparePrevious(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);
    const prior = Snapshot.readWithDirectoryEntries(self.io, self.inputs.arena.allocator(), self.slot.path, self.slot.value.directory_entries) catch |err| return self.fail(err);

    self.inputs.consistent = self.inputs.consistent and Snapshot.sameState(&self.slot.value.state, &prior);
}

pub fn commit(handle: *const anyopaque, directory_entries: bool) void {
    const self = Context.get(handle);
    const consumed = self.slot.existing and self.slot.value.consumed;

    self.slot.value.* = .{ .state = self.current, .directory_entries = directory_entries, .consumed = consumed };
}

pub fn recordFile(handle: *const anyopaque) Error!bool {
    const self = Context.get(handle);
    const slot = lookup(self.inputs, self.path) catch |err| return self.fail(err);
    self.slot = slot;

    const physical = std.Io.Dir.cwd().realPathFileAlloc(self.io, slot.path, self.inputs.arena.allocator()) catch |err| {
        self.inputs.consistent = false;
        self.slot.value.* = .{ .state = .{ .failed = err } };

        return self.fail(err);
    };

    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(self.bytes, &digest, .{});

    self.current = .{ .file = .{ .digest = digest, .physical_path = physical } };

    return self.slot.existing and self.slot.value.consumed;
}

pub fn compareRecorded(handle: *const anyopaque) void {
    const self = Context.get(handle);

    self.inputs.consistent = self.inputs.consistent and Snapshot.sameState(&self.slot.value.state, &self.current);
}

pub fn commitRecorded(handle: *const anyopaque) void {
    const self = Context.get(handle);

    self.slot.value.* = .{ .state = self.current, .consumed = true };
}
