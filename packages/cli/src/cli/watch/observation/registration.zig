const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const reader = @import("read.zig");
const storage = @import("storage.zig");
const Error = storage.Error;
const source = @import("cli_source");

const Slot = struct {
    path: []const u8,
    value: *Inputs.Observation,
    existing: bool,
};

pub const Context = struct {
    inputs: *Inputs,
    io: std.Io,
    slot: Slot = undefined,
    pending_path: ?[]const u8 = null,
    flags: storage.Slot = undefined,
    prior: storage.Fact = undefined,
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
    var context: Context = .{ .io = io, .inputs = inputs };
    const handle = &context;

    const admission = source.add.executeIn(inputs.arena.allocator(), &.{
        .registration = @ptrCast(&handle),
        .path = path,
        .directory_entries = directory_entries,
        .backend_input = false,
    }) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;

    return .{ .entry = context.slot.value, .inserted = admission == .New };
}

pub fn record(inputs: *Inputs, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var context: Context = .{ .io = io, .inputs = inputs };
    const handle = &context;
    var arena = std.heap.ArenaAllocator.init(inputs.arena.child_allocator);
    var space: [512]u8 = undefined;
    var storage_allocator = std.heap.BufferFirstAllocator.init(&space, arena.allocator());

    defer arena.deinit();

    source.record.executeIn(storage_allocator.allocator(), &.{ .registration = @ptrCast(&handle), .path = path, .bytes = bytes }) catch |err| {
        if (context.pending_path) |pending| _ = inputs.entries.remove(pending);

        return if (err == error.ObservationFailure) context.failure.? else err;
    };
}

pub fn openRegistration(handle: *const anyopaque, path: []const u8) Error!*const storage.Slot {
    const self = Context.get(handle);

    self.slot = if (self.inputs.entries.getEntry(path)) |entry|
        .{ .path = entry.key_ptr.*, .value = entry.value_ptr, .existing = true }

    else
        lookup(self.inputs, path) catch |err| return self.fail(err);

    const slot = self.slot;

    self.pending_path = if (slot.existing) null else slot.path;

    self.flags = .{
        .existing = slot.existing,
        .consumed = slot.existing and slot.value.consumed,
        .directory_entries = slot.existing and slot.value.directory_entries,
        .backend_preloaded = slot.existing and slot.value.backend_preloaded,
        .prior = if (slot.existing and slot.value.consumed) prior: {
            self.prior = Snapshot.fact(&slot.value.state);

            break :prior &self.prior;
        } else null,
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

pub fn resolveRecordedPath(handle: *const anyopaque) ?[]const u8 {
    const self = Context.get(handle);

    return reader.physicalPath(self.io, self.inputs.arena.allocator(), self.slot.path) catch |err| {
        self.failure = err;

        return null;
    };
}

pub fn publishObservation(handle: *const anyopaque, next: *const storage.Publication) Error!void {
    const self = Context.get(handle);

    if (!next.update_state) {
        self.slot.value.backend_preloaded = next.backend_preloaded;

        return;
    }

    self.inputs.consistent = self.inputs.consistent and next.consistent;

    self.slot.value.* = .{
        .state = if (self.failure) |err|
            .{ .failed = err }
        else if (next.recorded) |recorded|
            .{ .file = .{ .digest = recorded.digest[0..std.crypto.hash.sha2.Sha256.digest_length].*, .physical_path = recorded.physical_path } }
        else
            self.current,
        .directory_entries = next.directory_entries,
        .consumed = next.consumed,
        .backend_preloaded = next.backend_preloaded,
    };

    self.pending_path = null;

    if (self.failure != null) return error.ObservationFailure;
}
