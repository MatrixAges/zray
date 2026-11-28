const std = @import("std");
const Inputs = @import("../inputs.zig");
const Snapshot = @import("../snapshot.zig");
const source = @import("cli_source").observation_capture;

pub fn capture(inputs: *const Inputs, allocator: std.mem.Allocator) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const owned = arena.allocator();
    const count = inputs.entries.count();
    const paths = try temporary.alloc([]const u8, count);
    const rows = try temporary.alloc(*const Inputs.Observation, count);
    var iterator = inputs.entries.iterator();
    var index: usize = 0;

    while (iterator.next()) |entry| : (index += 1) {
        paths[index] = entry.key_ptr.*;
        rows[index] = entry.value_ptr;
    }

    const order = try source.executeValue(temporary, paths);
    const entries = try owned.alloc(Snapshot.Entry, count);

    for (entries, order) |*entry, row| {
        entry.* = try copyEntry(owned, paths[@intCast(row)], rows[@intCast(row)]);
    }

    return .{ .arena = arena, .entries = entries, .consistent = inputs.consistent };
}

fn copyEntry(allocator: std.mem.Allocator, logical: []const u8, observation: *const Inputs.Observation) !Snapshot.Entry {
    const path = try allocator.dupe(u8, logical);
    var state = observation.state;

    switch (state) {
        .directory, .file => |*content| {
            content.physical_path = if (std.mem.eql(u8, logical, content.physical_path)) path else try allocator.dupe(u8, content.physical_path);
        },
        else => {},
    }

    return .{ .path = path, .state = state, .directory_entries = observation.directory_entries };
}
