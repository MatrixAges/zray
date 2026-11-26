const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const storage = @import("storage.zig");
const Error = storage.Error;
const source = @import("cli_source").observation_capture;

const Context = struct {
    allocator: std.mem.Allocator,
    entries: []Snapshot.Entry,
    iterator: Inputs.Observations.Iterator,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return storage.context(Context, handle);
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

    const handle = &context;

    const order = source.executeValue(owned, &.{
        .capture = @ptrCast(&handle),
        .count = context.entries.len,
    }) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;

    if (order.len <= 1) return .{ .arena = arena, .entries = context.entries, .consistent = inputs.consistent };

    const sorted = try owned.alloc(Snapshot.Entry, order.len);

    for (order, 0..) |row, index| {
        sorted[index] = context.entries[@intCast(row)];
    }

    return .{ .arena = arena, .entries = sorted, .consistent = inputs.consistent };
}

pub fn captureEntry(handle: *const anyopaque, index: u64) Error![]const u8 {
    const self = Context.get(handle);

    return fill(self, @intCast(index)) catch |err| {
        self.failure = err;

        return error.ObservationFailure;
    };
}

fn fill(self: *Context, index: usize) ![]const u8 {
    const entry = self.iterator.next().?;
    const logical = entry.key_ptr.*;
    const path = try self.allocator.dupe(u8, logical);
    var state = entry.value_ptr.state;

    switch (state) {
        .directory, .file => |*content| {
            content.physical_path = if (std.mem.eql(u8, logical, content.physical_path))
                path

            else
                try self.allocator.dupe(u8, content.physical_path);
        },
        else => {},
    }

    self.entries[index] = .{ .path = path, .state = state, .directory_entries = entry.value_ptr.directory_entries };

    return path;
}
