const std = @import("std");
const builtin = @import("builtin");
const Backend = if (builtin.os.tag == .windows) @import("process/windows.zig") else @import("process/posix.zig");
const State = @import("driver/storage.zig").State;
const Error = @import("driver/storage.zig").Error;
const source = @import("cli_source");
const Run = struct { path: []const u8, process: Backend };
const Launch = struct { path: []const u8, argv: []const []const u8 = &.{} };

active: ?Run = null,

pending: ?Launch = null,
pub fn prepareApplication(handle: *const anyopaque) Error!?[]const u8 {
    const self = State.get(handle);

    prepare(self) catch |err| return recoverStart(self, err);

    return null;
}

fn prepare(self: *State) !void {
    const temporary = self.turn.?.arena.allocator();
    const output = self.options.output.?;
    var random: [16]u8 = undefined;

    std.Io.random(self.io, &random);

    const nonce = std.fmt.bytesToHex(random, .lower);
    const name = try source.application_name.executeIn(temporary, &.{ .basename = std.fs.path.basename(output), .nonce = &nonce, .windows = builtin.os.tag == .windows });
    const path = try std.fs.path.resolve(self.allocator, &.{ std.fs.path.dirname(output) orelse ".", name });

    std.Io.Dir.cwd().copyFile(output, .cwd(), path, self.io, .{ .replace = false }) catch |err| {
        self.allocator.free(path);

        return err;
    };

    self.application.pending = .{ .path = path };
    self.application.pending.?.argv = try source.application_arguments.executeIn(temporary, &.{ .path = path, .tail = self.options.run_args });
}

pub fn startApplication(handle: *const anyopaque) Error!?[]const u8 {
    const self = State.get(handle);
    const launch = self.application.pending.?;
    const child = Backend.start(self.io, launch.argv, self.environment) catch |err| return recoverStart(self, err);

    self.application.active = .{ .path = launch.path, .process = child };
    self.application.pending = null;

    return null;
}

pub fn applicationFinished(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const running = if (self.application.active) |*application| application else return false;

    return running.process.finished() catch |err| return self.fail(err);
}

pub fn stopApplication(handle: *const anyopaque, report_exit: bool) Error!?[]const u8 {
    const self = State.get(handle);

    stop(self, report_exit) catch |err| {
        if (report_exit) return self.fail(err);

        return recoverStart(self, err);
    };

    return null;
}

pub fn stop(self: *State, report_exit: bool) !void {
    const running = if (self.application.active) |*application| application else return;

    const term = stopped: {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        const path = running.path;
        const termination = try running.process.stop(self.io);

        self.application.active = null;

        try removeCopy(self, path);

        break :stopped termination;
    };

    if (report_exit) {
        try self.stderr.print("zxc watch: application {f}; waiting for changes\n", .{term});
        try self.stderr.flush();
    }
}

fn recoverStart(self: *State, err: anyerror) Error!?[]const u8 {
    discardPending(self);

    if (err == error.OutOfMemory or err == error.Canceled) return self.fail(err);

    return @errorName(err);
}

pub fn discardPending(self: *State) void {
    const launch = self.application.pending orelse return;
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);

    self.application.pending = null;

    removeCopy(self, launch.path) catch {};
}

fn removeCopy(self: *State, path: []const u8) !void {
    defer self.allocator.free(path);

    std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
