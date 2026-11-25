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
const Cycle = abi.layouts.@"zig:watch_host".Cycle;
const Poll = abi.layouts.@"zig:watch_host".Poll;
const Watch = std.meta.Child(@FieldType(Cycle, "watch"));
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
    parse_cache: ParseCache,
    last_success: ?Snapshot = null,
    last_failure: ?Snapshot = null,
    backend_paths: []const []const u8 = &.{},
    diagnostic: []const u8 = &.{},
    scan: ScanResult = undefined,
    cycles: DoubleBuffer(Cycle) = .{},
    polls: DoubleBuffer(Poll) = .{},
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
            .parse_cache = .{ .allocator = allocator, .keeps_replaced = true },
        };
    }

    pub fn deinit(self: *State) void {
        if (self.turn) |*turn| turn.deinit();

        self.allocator.free(self.diagnostic);
        self.parse_cache.deinit();
        self.backend_arena.deinit();
        self.replaceSnapshot(.Failure, null);
        self.replaceSnapshot(.Success, null);
        process.stopApplication(@ptrCast(&self)) catch {};
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

fn DoubleBuffer(comptime Row: type) type {
    return struct {
        rows: [2]Row = undefined,
        next: bool = false,
        fn write(self: *@This(), row: Row) *const Row {
            const destination = &self.rows[@intFromBool(self.next)];

            self.next = !self.next;
            destination.* = row;

            return destination;
        }
    };
}

pub fn writeCycle(handle: *const Watch, running: bool, status: Status) *const Cycle {
    const self = State.get(handle);

    return self.cycles.write(.{ .watch = handle, .cache = self.options.cache, .run_application = self.options.run, .running = running, .status = status });
}

pub fn writePoll(handle: *const Watch, snapshot: SnapshotSlot, retry_backend: bool, running: bool, scans: u64, changed: bool, scan_error: ?u16) *const Poll {
    return State.get(handle).polls.write(.{ .watch = handle, .snapshot = snapshot, .retry_backend = retry_backend, .running = running, .scans = scans, .changed = changed, .scan_error = scan_error });
}

pub fn announce(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stderr.print("zxc watch: watching {s}\n", .{self.options.input}) catch |err| return self.fail(err);
    self.stderr.flush() catch |err| return self.fail(err);
}

pub fn announceBuilt(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stderr.print("zxc watch: built {s}\n", .{self.options.output.?}) catch |err| return self.fail(err);
}

pub fn flush(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stderr.flush() catch |err| return self.fail(err);
    self.stdout.flush() catch |err| return self.fail(err);
}

pub fn clearDiagnostic(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.allocator.free(self.diagnostic);

    self.diagnostic = &.{};
}

pub fn reportDiagnostic(handle: *const anyopaque, normalize: bool) Error!void {
    const self = State.get(handle);
    const turn = &self.turn.?;
    const message = turn.diagnostics.written();
    const key = if (normalize) @import("../diagnostics.zig").key(turn.arena.allocator(), message) catch |err| return self.fail(err) else message;

    if (std.mem.eql(u8, key, self.diagnostic)) return;

    const owned = self.allocator.dupe(u8, key) catch |err| return self.fail(err);

    clearDiagnostic(handle);

    self.diagnostic = owned;

    self.stderr.writeAll(message) catch |err| return self.fail(err);
}
