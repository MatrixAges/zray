const std = @import("std");
const Cache = @import("cache.zig");
const Plan = @import("function_sources_plan.zig").Plan;

pub fn create(allocator: std.mem.Allocator, fetched: []const Cache.Fetched) std.mem.Allocator.Error!Plan {
    var reused: std.ArrayList(u64) = .empty;
    var pending: std.ArrayList(u64) = .empty;
    var offsets: std.ArrayList(u64) = .empty;
    var size: usize = 0;

    for (fetched, 0..) |value, position| {
        if (value.source) |source| {
            try reused.append(allocator, position);
            try offsets.append(allocator, size);

            size = std.math.add(usize, size, source.len) catch return error.OutOfMemory;
        } else {
            try pending.append(allocator, position);
        }
    }

    return .{ .reused = reused.items, .pending = pending.items, .offsets = offsets.items, .size = size, .records = .{ .first = 0, .end = fetched.len } };
}

pub fn restore(owned: std.mem.Allocator, fetched: []const Cache.Fetched, plan: Plan, target: [][]const u8, arenas: []std.heap.ArenaAllocator) @import("genz").zx.modules.Error!void {
    const buffer = try owned.alloc(u8, plan.size);
    var copying = Copying{ .plan = plan, .fetched = fetched, .buffer = buffer, .target = target };

    try @import("function_sources.zig").spread(Copying, &copying, arenas[0..@min(arenas.len, plan.reused.len)]);
}

const Copying = struct {
    plan: Plan,
    fetched: []const Cache.Fetched,
    buffer: []u8,
    target: [][]const u8,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    pub fn run(self: *Copying, _: *std.heap.ArenaAllocator) void {
        while (true) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.plan.reused.len) return;

            const index: usize = @intCast(self.plan.reused[position]);
            const source = self.fetched[index].source.?;
            const output = self.buffer[@intCast(self.plan.offsets[position])..][0..source.len];

            @memcpy(output, source);

            self.target[index] = output;
        }
    }
};
