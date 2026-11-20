const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const Error = @import("storage.zig").Error;
const source = @import("watch_observation").capture;

const Context = struct {
    allocator: std.mem.Allocator,
    entries: []Snapshot.Entry,
    iterator: Inputs.Observations.Iterator,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn capture(inputs: *const Inputs, allocator: std.mem.Allocator) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const owned = arena.allocator();

    var context: Context = .{
        .allocator = owned,
        .entries = try owned.alloc(Snapshot.Entry, inputs.entries.count()),
        .iterator = inputs.entries.iterator(),
    };

    source.executeValue(owned, @ptrCast(&context)) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;

    return .{ .arena = arena, .entries = context.entries, .consistent = inputs.consistent };
}

pub fn captureCount(handle: *const anyopaque) u64 {
    return Context.get(handle).entries.len;
}

pub fn captureEntry(handle: *const anyopaque, index: u64) Error!void {
    const self = Context.get(handle);

    fill(self, @intCast(index)) catch |err| {
        self.failure = err;

        return error.ObservationFailure;
    };
}

fn fill(self: *Context, index: usize) !void {
    const entry = self.iterator.next().?;
    const path = try self.allocator.dupe(u8, entry.key_ptr.*);
    var state = entry.value_ptr.state;

    switch (state) {
        .directory, .file => |*content| content.physical_path = try self.allocator.dupe(u8, content.physical_path),
        else => {},
    }

    self.entries[index] = .{ .path = path, .state = state, .directory_entries = entry.value_ptr.directory_entries };
}

pub fn sortCapture(handle: *const anyopaque) void {
    std.mem.sort(Snapshot.Entry, Context.get(handle).entries, {}, lessThan);
}

fn lessThan(_: void, left: Snapshot.Entry, right: Snapshot.Entry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}
