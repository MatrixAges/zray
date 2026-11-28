const std = @import("std");
const Options = @import("../../options.zig").Options;
const Inputs = @import("watch_inputs").Inputs;
const Snapshot = @import("watch_inputs").Snapshot;
const Attempt = @import("../attempt.zig");
pub const process = @import("../process.zig");
const ParseCache = @import("compiler").project.ParseCache;
const abi = @import("cli_abi");
pub const Status = abi.native.@"zig:watch_host".Status;
pub const SnapshotSlot = abi.native.@"zig:watch_host".SnapshotSlot;
pub const ScanResult = abi.layouts.@"zig:watch_host".ScanResult;
pub const Error = error{WatchFailure};
pub const build = @import("build.zig");
pub const wait = @import("wait.zig");

pub const Turn = struct {
    arena: std.heap.ArenaAllocator,
    inputs: Inputs,
    next_backend: std.heap.ArenaAllocator,
    attempt: Attempt = undefined,
    diagnostics: std.Io.Writer.Allocating = undefined,
    pub fn deinit(self: *Turn) void {
        self.inputs.deinit();
        self.next_backend.deinit();
        self.arena.deinit();
    }
};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    environment: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    application: process = .{},
    backend_arena: std.heap.ArenaAllocator,
    diagnostic_arena: std.heap.ArenaAllocator,
    parse_cache: ParseCache,
    last_success: ?Snapshot = null,
    last_failure: ?Snapshot = null,
    backend_paths: []const []const u8 = &.{},
    scan: ScanResult = undefined,
    turn: ?Turn = null,
    failure: ?anyerror = null,
    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) State {
        return .{
            .io = io,
            .allocator = allocator,
            .options = options,
            .environment = environment,
            .stdout = stdout,
            .stderr = stderr,
            .backend_arena = .init(allocator),
            .diagnostic_arena = .init(allocator),
            .parse_cache = .{ .allocator = allocator, .keeps_replaced = true },
        };
    }

    pub fn deinit(self: *State) void {
        if (self.turn) |*turn| turn.deinit();

        self.diagnostic_arena.deinit();
        self.parse_cache.deinit();
        self.backend_arena.deinit();
        self.replaceSnapshot(.Failure, null);
        self.replaceSnapshot(.Success, null);
        process.stopApplication(@ptrCast(&self), false) catch {};
    }

    pub fn get(handle: *const anyopaque) *State {
        return @import("publication_host").effects.state(State, handle);
    }
    pub fn replaceSnapshot(self: *State, slot: SnapshotSlot, next: ?Snapshot) void {
        const target = self.snapshotSlot(slot);

        if (target.*) |*previous| previous.deinit();

        target.* = next;
    }

    pub fn snapshotSlot(self: *State, slot: SnapshotSlot) *?Snapshot {
        return switch (slot) {
            .Success => &self.last_success,
            .Failure => &self.last_failure,
        };
    }

    pub fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.WatchFailure;
    }
};

pub fn writeWatchNotice(handle: *const anyopaque, prefix: []const u8, detail: []const u8, flush_now: bool) Error!void {
    const self = State.get(handle);

    self.stderr.print("{s}{s}\n", .{ prefix, detail }) catch |err| return self.fail(err);

    if (flush_now) self.stderr.flush() catch |err| return self.fail(err);
}

pub fn flush(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stderr.flush() catch |err| return self.fail(err);
    self.stdout.flush() catch |err| return self.fail(err);
}

pub fn reportDiagnostic(handle: *const anyopaque, normalize: bool, has_last: bool, last: []const u8) Error!?[]const u8 {
    const self = State.get(handle);
    const turn = &self.turn.?;
    const message = turn.diagnostics.written();
    const key = if (normalize) @import("../diagnostics.zig").key(turn.arena.allocator(), message) catch |err| return self.fail(err) else message;

    if (has_last and std.mem.eql(u8, key, last)) return null;

    _ = self.diagnostic_arena.reset(.retain_capacity);

    const owned = self.diagnostic_arena.allocator().dupe(u8, key) catch |err| return self.fail(err);

    self.stderr.writeAll(message) catch |err| return self.fail(err);

    return owned;
}
