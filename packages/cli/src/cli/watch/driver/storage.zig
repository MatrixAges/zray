const std = @import("std");
const Options = @import("../../options.zig").Options;
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const Attempt = @import("../attempt.zig");
const Process = @import("../process.zig");
const ParseCache = @import("compiler").project.ParseCache;
const abi = @import("cli_watch_abi").native.@"zig:watch_host";
pub const Status = abi.Status;
pub const Scan = abi.Scan;
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
    application: Process,
    backend_arena: std.heap.ArenaAllocator,
    parse_cache: ParseCache,
    last_success: ?Snapshot = null,
    last_failure: ?Snapshot = null,
    backend_paths: []const []const u8 = &.{},
    diagnostic: []const u8 = &.{},
    status: Status = .Retry,
    scan_error: ?anyerror = null,
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
            .application = .{ .allocator = allocator },
            .backend_arena = .init(allocator),
            .parse_cache = .{ .allocator = allocator, .keeps_replaced = true },
        };
    }

    pub fn deinit(self: *State) void {
        if (self.turn) |*turn| turn.deinit();

        self.allocator.free(self.diagnostic);
        self.parse_cache.deinit();
        self.backend_arena.deinit();

        if (self.last_failure) |*snapshot| snapshot.deinit();
        if (self.last_success) |*snapshot| snapshot.deinit();

        self.application.deinit(self.io);
    }

    pub fn get(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }

    pub fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.WatchFailure;
    }
};

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
