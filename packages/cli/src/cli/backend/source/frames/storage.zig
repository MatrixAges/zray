const std = @import("std");
const Server = std.zig.Server;
const Protocol = @import("../../protocol.zig");
const Error = error{BackendProtocolFailure};

pub const Context = struct {
    owned: std.mem.Allocator,
    temporary: std.mem.Allocator,
    selected: ?[]const u8 = null,
    path_layout: u64 = 0,
    path_bytes: []u8 = &.{},
    inputs: []Protocol.Input = &.{},
    diagnostics: std.zig.ErrorBundle = .empty,
    digest: ?[std.Build.Cache.bin_digest_len]u8 = null,
    cached: bool = false,
    failure: ?anyerror = null,
    fn get(handle: *anyopaque) *Context {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.BackendProtocolFailure;
    }
};

pub fn commitInputs(handle: *anyopaque, body: []const u8, layout: ?u64) void {
    const self = Context.get(handle);

    self.selected = body;
    self.path_layout = layout.?;
}

pub fn commitDigest(handle: *anyopaque, body: []const u8, cached: ?bool) void {
    const self = Context.get(handle);

    self.digest = body[1..][0..std.Build.Cache.bin_digest_len].*;
    self.cached = cached.?;
}

pub fn commitDiagnostics(handle: *anyopaque, body: []const u8) Error!void {
    const self = Context.get(handle);
    const bundle = Server.allocErrorBundle(self.owned, body) catch |err| return self.fail(err);

    Protocol.diagnostics.validate(self.temporary, bundle) catch |err| return self.fail(err);

    self.diagnostics = bundle;
}

pub fn hasDiagnostics(handle: *anyopaque) bool {
    return Context.get(handle).diagnostics.errorMessageCount() != 0;
}

pub fn hasInputs(handle: *anyopaque) bool {
    return Context.get(handle).selected != null;
}

pub fn inputLayout(handle: *anyopaque) u64 {
    return Context.get(handle).path_layout;
}

pub fn selectedInputBytes(handle: *anyopaque) []const u8 {
    return Context.get(handle).selected.?;
}

pub fn reserveInputs(handle: *anyopaque, count: u64, length: u64) Error!void {
    const self = Context.get(handle);
    const path_bytes = self.owned.alloc(u8, @intCast(length)) catch |err| return self.fail(err);

    errdefer self.owned.free(path_bytes);

    const inputs = self.owned.alloc(Protocol.Input, @intCast(count)) catch |err| return self.fail(err);

    self.path_bytes = path_bytes;
    self.inputs = inputs;
}

pub fn writeInput(handle: *anyopaque, row: u64, prefix: u8, offset: u64, spelling: []const u8) void {
    const self = Context.get(handle);
    const path = self.path_bytes[@intCast(offset)..][0..spelling.len];

    @memcpy(path, spelling);
    self.inputs[@intCast(row)] = .{ .prefix = @fromBackingInt(@intCast(prefix)), .path = path };
}
