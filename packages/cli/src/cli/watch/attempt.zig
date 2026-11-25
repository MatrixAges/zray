const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const Self = @This();

allocator: std.mem.Allocator,
inputs: *Inputs,
previous_backend: []const []const u8,
backend_owner: *std.heap.ArenaAllocator,
parse_cache: ?*@import("compiler").project.ParseCache,
backend_paths: ?[]const []const u8 = null,
preloaded: std.ArrayList([]const u8) = .empty,
pub fn prepareBackend(self: *Self, io: std.Io) !void {
    for (self.previous_backend) |path| {
        if (self.inputs.entries.contains(path)) continue;
        try self.preloaded.append(self.allocator, path);

        self.inputs.add(io, path) catch |err| {
            if (err == error.OutOfMemory) return err;
        };
    }
}

pub fn finishBackend(self: *Self, paths: []const []const u8) !void {
    var current: std.StringHashMapUnmanaged(void) = .empty;

    if (self.preloaded.items.len != 0) {
        for (paths) |path| try current.put(self.allocator, path, {});

        for (self.preloaded.items) |path| {
            if (!current.contains(path)) _ = self.inputs.entries.remove(path);
        }
    }

    self.backend_paths = paths;
}
