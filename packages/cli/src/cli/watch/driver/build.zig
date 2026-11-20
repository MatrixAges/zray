const std = @import("std");
const Inputs = @import("../inputs.zig");
const compiler = @import("../../compile.zig");
const storage = @import("storage.zig");
const State = storage.State;
const Error = storage.Error;

pub fn begin(handle: *const anyopaque, cache: bool) Error!void {
    const self = State.get(handle);
    const inputs = Inputs.init(self.io, self.allocator) catch |err| return self.fail(err);
    self.turn = .{ .arena = .init(self.allocator), .next_backend = .init(self.allocator), .inputs = inputs };

    const turn = &self.turn.?;
    const temporary = turn.arena.allocator();

    turn.inputs.retain_versions = cache;

    if (cache) turn.inputs.previous = self.last_success orelse self.last_failure;

    turn.attempt = .{
        .allocator = temporary,
        .inputs = &turn.inputs,
        .previous_backend = self.backend_paths,
        .backend_owner = &turn.next_backend,
        .parse_cache = if (cache) &self.parse_cache else null,
    };

    turn.diagnostics = .init(temporary);
}

pub fn compile(handle: *const anyopaque) Error!storage.Status {
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

    self.status = switch (status) {
        .success => .Success,
        .failed => .Failed,
        .retry => .Retry,
        .backend_failed => .BackendFailed,
    };

    return self.status;
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

pub fn commitSuccess(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const inputs = &self.turn.?.inputs;
    const next = inputs.takePublished() orelse (inputs.observed(self.allocator) catch |err| return self.fail(err));

    if (self.last_success) |*snapshot| snapshot.deinit();

    self.last_success = next;

    if (self.last_failure) |*snapshot| snapshot.deinit();

    self.last_failure = null;
}

pub fn restart(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.application.restart(self.io, self.options, self.environment) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

        self.stderr.print("zxc watch: application start: {s}\n", .{@errorName(err)}) catch |failure| return self.fail(failure);
    };
}

pub fn priorCount(handle: *const anyopaque) u64 {
    const self = State.get(handle);

    return if (self.last_success) |snapshot| snapshot.entries.len else 0;
}

pub fn reobserve(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const entry = &self.last_success.?.entries[@intCast(index)];
    const inputs = &self.turn.?.inputs;

    (if (entry.directory_entries) inputs.addDirectory(self.io, entry.path) else inputs.add(self.io, entry.path)) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);
    };
}

pub fn commitFailure(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const next = self.turn.?.inputs.observed(self.allocator) catch |err| return self.fail(err);

    if (self.last_failure) |*snapshot| snapshot.deinit();

    self.last_failure = next;
}

pub fn releaseTurn(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.turn.?.deinit();

    self.turn = null;
}
