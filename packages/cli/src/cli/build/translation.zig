const std = @import("std");
const protocol = @import("backend_protocol");
const Cache = @import("observed.zig").Cache;
const Self = @This();

arena: std.heap.ArenaAllocator,
cache: Cache,
responses: std.ArrayList(protocol.Result) = .empty,
pending: ?protocol.Result = null,
pub fn deinit(self: *Self) void {
    if (self.pending) |*pending| pending.deinit();
    for (self.responses.items) |*response| response.deinit();

    self.arena.deinit();
}
