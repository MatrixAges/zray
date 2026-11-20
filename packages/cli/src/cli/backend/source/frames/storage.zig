const std = @import("std");
const Server = std.zig.Server;
const Protocol = @import("../../protocol.zig");
const Error = error{BackendProtocolFailure};
const word_range = @import("backend_source").diagnostic_constants.@"zx.constants".word_range;

pub const Context = struct {
    owned: std.mem.Allocator,
    temporary: std.mem.Allocator,
    selected: ?[]const u8 = null,
    path_count: usize = 0,
    path_bytes: usize = 0,
    inputs: []const Protocol.Input = &.{},
    diagnostics: std.zig.ErrorBundle = .empty,
    digest: ?[std.Build.Cache.bin_digest_len]u8 = null,
    cached: bool = false,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.BackendProtocolFailure;
    }
};

pub fn commitInputs(handle: *const anyopaque, body: []const u8, layout: ?u64) void {
    const self = Context.get(handle);

    self.selected = body;
    self.path_count = @intCast(layout.? / word_range);
    self.path_bytes = @intCast(layout.? % word_range);
}

pub fn commitDigest(handle: *const anyopaque, body: []const u8, cached: ?bool) void {
    const self = Context.get(handle);

    self.digest = body[1..][0..std.Build.Cache.bin_digest_len].*;
    self.cached = cached.?;
}

pub fn commitDiagnostics(handle: *const anyopaque, body: []const u8) Error!void {
    const self = Context.get(handle);
    const bundle = Server.allocErrorBundle(self.owned, body) catch |err| return self.fail(err);

    Protocol.diagnostics.validate(self.temporary, bundle) catch |err| return self.fail(err);

    self.diagnostics = bundle;
}

pub fn hasDiagnostics(handle: *const anyopaque) bool {
    return Context.get(handle).diagnostics.errorMessageCount() != 0;
}

pub fn hasInputs(handle: *const anyopaque) bool {
    return Context.get(handle).selected != null;
}

pub fn materializeInputs(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    if (self.path_count == 0) return;

    var bytes = self.owned.alloc(u8, self.path_bytes) catch |err| return self.fail(err);
    const inputs = self.owned.alloc(Protocol.Input, self.path_count) catch |err| return self.fail(err);
    var paths = std.mem.tokenizeScalar(u8, self.selected.?, 0);

    for (inputs) |*input| {
        const encoded = paths.next().?;
        const path = bytes[0 .. encoded.len - 1];

        @memcpy(path, encoded[1..]);

        input.* = .{ .prefix = @fromBackingInt(@intCast(encoded[0] - 1)), .path = path };
        bytes = bytes[path.len..];
    }

    self.inputs = inputs;
}
