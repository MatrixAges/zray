const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const compiler = @import("../../compile.zig");
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;
const CompilationTurn = @import("cli_abi").layouts.@"zig:watch_host".CompilationTurn;
const ObservedEntryLayout = @import("cli_abi").layouts.@"zig:watch_host".ObservedEntry;
const ObservedEntry = @import("cli_abi").native.@"zig:watch_host".ObservedEntry;

pub fn begin(handle: *const anyopaque, cache: bool, previous: ?storage.SnapshotSlot) Error!void {
    const self = State.get(handle);
    const inputs = Inputs.init(self.io, self.allocator) catch |err| return self.fail(err);
    self.turn = .{ .arena = .init(self.allocator), .next_backend = .init(self.allocator), .inputs = inputs };

    const turn = &self.turn.?;
    const temporary = turn.arena.allocator();

    turn.inputs.retain_versions = cache;

    if (previous) |slot| if (self.snapshotSlot(slot).*) |*snapshot| {
        turn.inputs.previous = snapshot;
    };

    turn.attempt = .{
        .inputs = &turn.inputs,
        .previous_backend = self.backend_paths,
        .backend_owner = &turn.next_backend,
        .parse_cache = if (cache) &self.parse_cache else null,
    };

    turn.diagnostics = .init(temporary);
}

pub fn compileTurn(handle: *const anyopaque) Error!*const CompilationTurn {
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

    turn.compilation = .{
        .status = switch (status) {
            .success => .Success,
            .failed => .Failed,
            .retry => .Retry,
            .backend_failed => .BackendFailed,
        },
        .diagnostic = turn.diagnostics.written(),
    };

    return &turn.compilation;
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

    @import("cli_source").restart_application.executeIn(self.turn.?.arena.allocator(), @ptrCast(handle)) catch |cause| {
        const err = if (cause == error.WatchFailure) self.failure.? else cause;

        storage.process.discardPending(self);

        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

        self.stderr.print("zxc watch: application start: {s}\n", .{@errorName(err)}) catch |failure| return self.fail(failure);
    };
}

pub fn snapshotEntries(handle: *const anyopaque, slot: storage.SnapshotSlot) Error![]const ObservedEntry {
    const self = State.get(handle);
    const snapshot = self.snapshotSlot(slot).* orelse return &.{};
    const allocator = self.turn.?.arena.allocator();
    const values = allocator.alloc(ObservedEntryLayout, snapshot.entries.len) catch |err| return self.fail(err);
    const ptrs = allocator.alloc(ObservedEntry, snapshot.entries.len) catch |err| return self.fail(err);

    for (snapshot.entries, values, ptrs) |entry, *value, *ptr| {
        value.* = .{
            .path = entry.path,
            .directory = entry.directory_entries,
        };

        ptr.* = value;
    }

    return ptrs;
}

pub fn reobservePath(handle: *const anyopaque, path: []const u8, directory: bool) Error!void {
    const self = State.get(handle);
    const inputs = &self.turn.?.inputs;

    (if (directory) inputs.addDirectory(self.io, path) else inputs.add(self.io, path)) catch |err| {
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
