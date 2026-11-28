const std = @import("std");
const abi = @import("cli_abi");
const rule = @import("cli_source").download;
const constants = @import("../store.zig").constants;
const ResponseHead = abi.layouts.@"zig:package_download_host".ResponseHead;
const Error = error{PackageDownloadHostFailure};

const State = struct {
    client: std.http.Client,
    request: ?std.http.Client.Request = null,
    response: std.http.Client.Response = undefined,
    head_view: ResponseHead = undefined,
    redirect_buffer: [8192]u8 = undefined,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *State {
        return @as(*const *State, @ptrCast(@alignCast(handle))).*;
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

        self.client.deinit();
    }
};

pub const Downloaded = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []const u8,
    pub fn deinit(self: *Downloaded) void {
        self.arena.deinit();
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, source: []const u8, base: []const u8) !Downloaded {
    const transport = try @import("pkgs").install.archiveTransport(allocator, source);
    var state: State = .{ .client = .{ .io = io, .allocator = allocator } };
    const reader = &state;
    var accepted = false;

    defer state.deinit(accepted);

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const result = rule.executeIn(arena.allocator(), &.{
        .reader = @ptrCast(&reader),
        .source = source,
        .base = base,
        .is_local = transport == .Local,
        .maximum_archive = constants.maximum_archive,
    }, io) catch |err| return if (err == error.PackageDownloadHostFailure) state.failure.? else err;

    switch (result.status) {
        .Ready => accepted = true,
        .PackageArchiveTooLarge => return error.PackageArchiveTooLarge,
        .PackageDownloadFailed => return error.PackageDownloadFailed,
        .UnsupportedPackageContentEncoding => return error.UnsupportedPackageContentEncoding,
    }

    return .{ .arena = arena, .bytes = result.body.? };
}

pub fn receiveHead(handle: *const anyopaque, url: []const u8) Error!*const ResponseHead {
    const self = State.get(handle);
    const uri = std.Uri.parse(url) catch |err| return self.fail(err);

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

pub fn readBody(allocator: std.mem.Allocator, handle: *const anyopaque, limit: u64) Error![]const u8 {
    const self = State.get(handle);
    var buffer: [65536]u8 = undefined;

    return self.response.reader(&buffer).allocRemaining(allocator, .limited(@intCast(limit))) catch |err| self.fail(err);
}
