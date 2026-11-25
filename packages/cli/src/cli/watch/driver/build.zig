const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const Snapshot = @import("watch_inputs").Snapshot;
const compiler = @import("../../compile.zig");
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;
const SnapshotReference = @import("cli_watch_abi").native.@"zig:watch_host".Snapshot;

pub fn begin(handle: *const anyopaque, cache: bool, previous: ?*const anyopaque) Error!void {
    const self = State.get(handle);
    const inputs = Inputs.init(self.io, self.allocator) catch |err| return self.fail(err);
    self.turn = .{ .arena = .init(self.allocator), .next_backend = .init(self.allocator), .inputs = inputs };

    const turn = &self.turn.?;
    const temporary = turn.arena.allocator();

    turn.inputs.retain_versions = cache;

    if (previous) |snapshot| turn.inputs.previous = @ptrCast(@alignCast(snapshot));

    turn.attempt = .{
        .allocator = temporary,
        .inputs = &turn.inputs,
        .previous_backend = self.backend_paths,
        .backend_owner = &turn.next_backend,
        .parse_cache = if (cache) &self.parse_cache else null,
    };

    turn.diagnostics = .init(temporary);
}

pub fn compileTurn(handle: *const anyopaque) Error!storage.Status {
    const self = State.get(handle);
    const turn = &self.turn.?;

    const status = compiler.run(.{
        .io = self.io,
        .allocator = turn.arena.allocator(),
        .backing = self.allocator,
        .options = self.options,
        .environment = self.environment,
        .stdout = self.stdout,
        .stderr = &turn.diagnostics.writer,
        .watch = &turn.attempt,
    }) catch |err| failed: {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

        turn.diagnostics.writer.print("{s}: {s}\n", .{ self.options.input, @errorName(err) }) catch |failure| return self.fail(failure);

        break :failed .failed;
    };

    return switch (status) {
        .success => .Success,
        .failed => .Failed,
        .retry => .Retry,
        .backend_failed => .BackendFailed,
    };
}

pub fn refreshParseCache(handle: *const anyopaque) void {
    const turn = &State.get(handle).turn.?;

    if (turn.attempt.parse_cache) |cache| {
        cache.release();
        cache.retainPaths(&turn.inputs.entries);
    }
}

pub fn adoptBackend(handle: *const anyopaque) void {
    const self = State.get(handle);
    const turn = &self.turn.?;
    const paths = turn.attempt.backend_paths orelse return;

    self.backend_arena.deinit();

    self.backend_arena = turn.next_backend;
    self.backend_paths = paths;
    turn.next_backend = .init(self.allocator);
}

pub fn adoptPublishedSnapshot(handle: *const anyopaque) bool {
    const self = State.get(handle);
    const snapshot = self.turn.?.inputs.takePublished() orelse return false;

    self.replaceSnapshot(.Success, snapshot);

    return true;
}

pub fn restart(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.application.restart(self.io, self.options, self.environment) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

        self.stderr.print("zxc watch: application start: {s}\n", .{@errorName(err)}) catch |failure| return self.fail(failure);
    };
}

pub fn borrowSnapshot(handle: *const anyopaque, slot: storage.SnapshotSlot) ?SnapshotReference {
    const snapshot = State.get(handle).snapshotSlot(slot);

    return if (snapshot.*) |*value| @ptrCast(value) else null;
}

pub fn snapshotLength(snapshot: *const anyopaque) u64 {
    const value: *const Snapshot = @ptrCast(@alignCast(snapshot));

    return value.entries.len;
}

pub fn reobserve(handle: *const anyopaque, snapshot: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const value: *const Snapshot = @ptrCast(@alignCast(snapshot));
    const entry = &value.entries[@intCast(index)];
    const inputs = &self.turn.?.inputs;

    (if (entry.directory_entries) inputs.addDirectory(self.io, entry.path) else inputs.add(self.io, entry.path)) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);
    };
}

pub fn captureSnapshot(handle: *const anyopaque, slot: storage.SnapshotSlot) Error!void {
    const self = State.get(handle);
    const next = self.turn.?.inputs.observed(self.allocator) catch |err| return self.fail(err);

    self.replaceSnapshot(slot, next);
}

pub fn releaseSnapshot(handle: *const anyopaque, slot: storage.SnapshotSlot) void {
    State.get(handle).replaceSnapshot(slot, null);
}

pub fn releaseTurn(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.turn.?.deinit();

    self.turn = null;
}
