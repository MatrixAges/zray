const std = @import("std");
const protocol = @import("backend_protocol");
const source = @import("cli_source");
const Cache = @import("observed.zig").Cache;
const Self = @This();

arena: std.heap.ArenaAllocator,
cache: Cache,
observed: bool,
responses: std.ArrayList(protocol.Result) = .empty,
failure: ?protocol.Result = null,
pub fn init(allocator: std.mem.Allocator, cache: Cache, observed: bool) Self {
    return .{ .arena = .init(allocator), .cache = cache, .observed = observed };
}

pub fn deinit(self: *Self) void {
    if (self.failure) |*failure| failure.deinit();
    for (self.responses.items) |*response| response.deinit();

    self.arena.deinit();
}

pub fn execute(self: *Self, io: std.Io, arguments: []const []const u8, environment: *const std.process.Environ.Map, stem: []const u8) !?[]const u8 {
    const allocator = self.arena.allocator();
    var response = try @import("../backend/process.zig").run(io, self.arena.child_allocator, arguments, environment);
    var retained = false;

    defer if (!retained) response.deinit();

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const disposition = source.backend_translation_retention.executeIn(empty.allocator(), &.{
        .succeeded = response.succeeded,
        .observed = self.observed,
    }) catch unreachable;

    switch (disposition) {
        .Failed => {
            self.failure = response;
            retained = true;

            return null;
        },
        .Observe => {
            try self.responses.append(allocator, response);

            retained = true;
        },
        .Release => {},
    }

    const location = try source.backend_cache_path.executeIn(allocator, &.{
        .digest = &response.digest.?,
        .stem = stem,
        .separator = "/",
    });

    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.cache.local, location });
}
