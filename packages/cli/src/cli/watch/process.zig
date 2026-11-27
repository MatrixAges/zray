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
termination: std.process.Child.Term = undefined,
pub fn prepareApplication(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const temporary = self.turn.?.arena.allocator();
    const output = self.options.output.?;

    var random: [16]u8 = undefined;

    std.Io.random(self.io, &random);

    const nonce = std.fmt.bytesToHex(random, .lower);
    const name = source.application_name.executeIn(temporary, &.{ .basename = std.fs.path.basename(output), .nonce = &nonce, .windows = builtin.os.tag == .windows }) catch |err| return self.fail(err);
    const path = std.fs.path.resolve(self.allocator, &.{ std.fs.path.dirname(output) orelse ".", name }) catch |err| return self.fail(err);

    std.Io.Dir.cwd().copyFile(output, .cwd(), path, self.io, .{ .replace = false }) catch |err| {
        self.allocator.free(path);

        return self.fail(err);
    };

    self.application.pending = .{ .path = path };
    self.application.pending.?.argv = source.application_arguments.executeIn(temporary, &.{ .path = path, .tail = self.options.run_args }) catch |err| return self.fail(err);
}

pub fn startApplication(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const launch = self.application.pending.?;
    const child = Backend.start(self.io, launch.argv, self.environment) catch |err| return self.fail(err);

    self.application.active = .{ .path = launch.path, .process = child };
    self.application.pending = null;
}

pub fn applicationFinished(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const running = if (self.application.active) |*application| application else return false;

    return running.process.finished() catch |err| return self.fail(err);
}

pub fn stopApplication(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const running = if (self.application.active) |*application| application else return;
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    const path = running.path;

    self.application.termination = running.process.stop(self.io) catch |err| return self.fail(err);
    self.application.active = null;

    removeCopy(self, path) catch |err| return self.fail(err);
}

pub fn reportApplicationExit(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stderr.print("zxc watch: application {f}; waiting for changes\n", .{self.application.termination}) catch |err| return self.fail(err);
    self.stderr.flush() catch |err| return self.fail(err);
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
