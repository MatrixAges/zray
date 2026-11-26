const std = @import("std");
const abi = @import("cli_abi");
const rule = @import("cli_source").download;
const constants = @import("../store.zig").constants;
const ResponseHead = abi.layouts.@"zig:package_download_host".ResponseHead;
const Error = error{PackageDownloadHostFailure};

const State = struct {
    client: std.http.Client,
    source: []const u8,
    base: []const u8,
    request: ?std.http.Client.Request = null,
    response: std.http.Client.Response = undefined,
    head_view: ResponseHead = undefined,
    redirect_buffer: [8192]u8 = undefined,
    body: ?[]u8 = null,
    failure: ?anyerror = null,
    fn get(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.PackageDownloadHostFailure;
    }

    fn deinit(self: *State, accepted: bool) void {
        if (self.request) |*request| {
            if (!accepted) {
                if (request.connection) |connection| connection.closing = true;
            }

            request.deinit();
        }

        if (!accepted) {
            if (self.body) |body| self.client.allocator.free(body);
        }

        self.client.deinit();
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, source: []const u8, base: []const u8) ![]u8 {
    const transport = try @import("pkgs").install.archiveTransport(allocator, source);
    var state: State = .{ .client = .{ .io = io, .allocator = allocator }, .source = source, .base = base };
    var accepted = false;

    defer state.deinit(accepted);

    const result = rule.executeIn(allocator, &.{
        .download = @ptrCast(&state),
        .is_local = transport == .Local,
    }) catch |err| return if (err == error.PackageDownloadHostFailure) state.failure.? else err;

    switch (result) {
        .Ready => accepted = true,
        .PackageArchiveTooLarge => return error.PackageArchiveTooLarge,
        .PackageDownloadFailed => return error.PackageDownloadFailed,
        .UnsupportedPackageContentEncoding => return error.UnsupportedPackageContentEncoding,
    }

    return state.body.?;
}

pub fn readLocal(handle: *anyopaque, limit: u64) Error!u64 {
    const self = State.get(handle);
    const allocator = self.client.allocator;
    const path = std.fs.path.resolve(allocator, &.{ self.base, self.source }) catch |err| return self.fail(err);

    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(self.client.io, path, allocator, .limited(@intCast(limit))) catch |err| return self.fail(err);

    self.body = bytes;

    return bytes.len;
}

pub fn receiveHead(handle: *anyopaque) Error!*const ResponseHead {
    const self = State.get(handle);
    const uri = std.Uri.parse(self.source) catch |err| return self.fail(err);

    self.request = self.client.request(.GET, uri, .{
        .redirect_behavior = @fromBackingInt(constants.maximum_redirects),
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch |err| return self.fail(err);

    const request = &self.request.?;

    request.sendBodiless() catch |err| return self.fail(err);

    self.response = request.receiveHead(&self.redirect_buffer) catch |err| return self.fail(err);

    self.head_view = .{
        .ok = self.response.head.status == .ok,
        .identity = self.response.head.content_encoding == .identity,
        .length = self.response.head.content_length,
    };

    return &self.head_view;
}

pub fn readBody(handle: *anyopaque, limit: u64) Error!void {
    const self = State.get(handle);
    var buffer: [65536]u8 = undefined;

    self.body = self.response.reader(&buffer).allocRemaining(self.client.allocator, .limited(@intCast(limit))) catch |err| return self.fail(err);
}
