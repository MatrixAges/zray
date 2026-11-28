const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const reader = @import("read.zig");
const storage = @import("storage.zig");
const Error = storage.Error;
const source = @import("cli_source");

const Target = struct {
    path: []const u8,
    value: ?*Inputs.Observation,
};

pub const Context = struct {
    inputs: *Inputs,
    io: std.Io,
    target: Target = undefined,
    slot: storage.Slot = undefined,
    prior: storage.Fact = undefined,
    previous_fact: storage.Fact = undefined,
    version: reader.VersionFields = undefined,
    version_request: storage.VersionRequest = undefined,
    reusable: storage.Prior = undefined,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return storage.context(Context, handle);
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.ObservationFailure;
    }
};

pub const Addition = struct { entry: *Inputs.Observation, inserted: bool };

pub fn add(inputs: *Inputs, io: std.Io, path: []const u8, directory_entries: bool) !Addition {
    var context: Context = .{ .io = io, .inputs = inputs };
    const handle = &context;
    var arena = std.heap.ArenaAllocator.init(inputs.arena.child_allocator);
    var space: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&space, arena.allocator());

    defer arena.deinit();

    const admission = source.add.executeIn(scratch.allocator(), &.{
        .registration = @ptrCast(&handle),
        .path = path,
        .directory_entries = directory_entries,
        .backend_input = false,
    }) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;

    return .{ .entry = context.target.value.?, .inserted = admission == .New };
}

pub fn record(inputs: *Inputs, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var target = try lookup(inputs, path);
    var arena = std.heap.ArenaAllocator.init(inputs.arena.child_allocator);
    var space: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&space, arena.allocator());

    defer arena.deinit();

    const allocator = scratch.allocator();
    var failure: u32 = 0;

    const physical = reader.physicalPath(io, allocator, target.path) catch |err| no_path: {
        failure = @intFromError(err);

        break :no_path null;
    };

    const existing = target.value;
    const prior = if (existing != null and existing.?.consumed) Snapshot.fact(&existing.?.state) else null;

    const next = try source.record.executeIn(allocator, &.{
        .bytes = bytes,
        .physical_path = physical,
        .failure = failure,
        .backend_preloaded = existing != null and existing.?.backend_preloaded,
        .prior = if (prior) |*fact| fact else null,
    });

    try publish(inputs, &target, next);
}

fn lookup(inputs: *Inputs, path: []const u8) !Target {
    if (inputs.entries.getEntry(path)) |entry| {
        return .{ .path = entry.key_ptr.*, .value = entry.value_ptr };
    }

    const allocator = inputs.arena.allocator();
    const normalized = try std.fs.path.resolve(allocator, &.{ inputs.cwd, path });

    if (inputs.entries.getEntry(normalized)) |entry| {
        allocator.free(normalized);

        return .{ .path = entry.key_ptr.*, .value = entry.value_ptr };
    }

    return .{ .path = normalized, .value = null };
}

pub fn openRegistration(handle: *const anyopaque, path: []const u8, directory_entries: bool) Error!*const storage.Slot {
    const self = Context.get(handle);

    self.target = lookup(self.inputs, path) catch |err| return self.fail(err);

    const value = self.target.value;
    const existing = value != null;

    if (value) |entry| self.prior = Snapshot.fact(&entry.state);

    self.slot = .{
        .path = self.target.path,
        .consumed = existing and value.?.consumed,
        .directory_entries = existing and value.?.directory_entries,
        .backend_preloaded = existing and value.?.backend_preloaded,
        .consistent = self.inputs.consistent,
        .prior = if (existing) &self.prior else null,
        .reusable = if (!existing and !directory_entries) previous(self, self.target.path) else null,
    };

    return &self.slot;
}

fn previous(self: *Context, path: []const u8) ?*const storage.Prior {
    const snapshot = self.inputs.previous orelse return null;
    const entry = snapshot.find(path) orelse return null;
    const verified = entry.verified_file orelse return null;

    self.previous_fact = Snapshot.fact(&entry.state);

    self.version.init(verified);

    self.version_request = .{ .previous = &self.version.view, .physical_path = entry.state.file.physical_path };
    self.reusable = .{ .request = &self.version_request, .fact = &self.previous_fact };

    return &self.reusable;
}

const empty_fact: storage.Fact = .{ .kind = .Missing, .tag = 0, .digest = &.{}, .physical_path = "" };

pub fn readCurrent(allocator: std.mem.Allocator, handle: *const anyopaque, request: *const storage.RegistrationRequest) std.mem.Allocator.Error!*const storage.RegistrationReading {
    const io = Context.get(handle).io;
    const result = try allocator.create(storage.RegistrationReading);

    if (request.previous) |prior| {
        const classification = try reader.classify(allocator, io, request.path, prior);

        const fact = if (classification.failure) |failure| failed: {
            const value = try allocator.create(storage.Fact);
            value.* = .{ .kind = .Failed, .tag = failure, .digest = &.{}, .physical_path = "" };

            break :failed value;
        } else &empty_fact;

        result.* = .{ .fact = fact, .unchanged = classification.unchanged };

        return result;
    }

    const reading = try source.read.executeIn(allocator, &.{
        .path = request.path,
        .directory_entries = request.directory_entries,
        .started = null,
    }, io);

    result.* = .{ .fact = reading.fact, .unchanged = false };

    return result;
}

pub fn publishObservation(handle: *const anyopaque, next: *const storage.Publication) Error!void {
    const self = Context.get(handle);

    publish(self.inputs, &self.target, next) catch |err| return self.fail(err);
}

fn publish(inputs: *Inputs, target: *Target, next: *const storage.Publication) !void {
    if (next.failure) |failure| return reader.failure(failure);

    const fact = next.fact orelse {
        target.value.?.backend_preloaded = next.backend_preloaded;

        return;
    };

    const allocator = inputs.arena.allocator();

    const state: Snapshot.State = switch (fact.kind) {
        .Missing => .missing,
        .Failed => .{ .failed = reader.failure(fact.tag) },
        .Other => .{ .other = @fromBackingInt(@intCast(fact.tag)) },
        .File, .Directory => content: {
            const path = if (std.mem.eql(u8, fact.physical_path, target.path))
                target.path

            else
                try allocator.dupe(u8, fact.physical_path);

            const content: Snapshot.Content = .{ .digest = fact.digest[0..32].*, .physical_path = path };

            break :content if (fact.kind == .File) .{ .file = content } else .{ .directory = content };
        },
    };

    const value = target.value orelse (try inputs.entries.getOrPut(allocator, target.path)).value_ptr;

    value.* = .{
        .state = state,
        .directory_entries = next.directory_entries,
        .consumed = next.consumed,
        .backend_preloaded = next.backend_preloaded,
    };

    target.value = value;
    inputs.consistent = inputs.consistent and next.consistent;

    if (state == .failed) return state.failed;
}
