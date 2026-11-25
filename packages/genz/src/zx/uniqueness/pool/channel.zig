const std = @import("std");
const zx = @import("zx");
const constants = @import("generated_uniqueness_pool_limits").@"zx.constants";
const reserving = @import("generated_uniqueness_pool_reserve");
const submitting = @import("generated_uniqueness_pool_submit");
const taking = @import("generated_uniqueness_pool_take");
const completing = @import("generated_uniqueness_pool_complete");
const draining = @import("generated_uniqueness_pool_drain");
const stopping = @import("generated_uniqueness_pool_stop");
const Self = @This();
pub const max_threads = constants.max_threads;

counters: [constants.counter_count]u32 = @splat(0),
ring: []u32,
pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
    return .{ .ring = try allocator.alloc(u32, constants.capacity) };
}

pub fn reserve(self: *Self) ?u32 {
    return self.countersCall(reserving);
}

pub fn publish(self: *Self, position: u32, index: u32) void {
    var counters: []u32 = &self.counters;

    const input: std.meta.Child(submitting.Input) = .{
        .counters = @ptrCast(&counters),
        .ring = @ptrCast(&self.ring),
        .position = position,
        .index = index,
    };

    invoke(submitting, &input);
}

pub fn take(self: *Self) ?u32 {
    var counters: []u32 = &self.counters;
    const input: std.meta.Child(taking.Input) = .{ .counters = @ptrCast(&counters), .ring = @ptrCast(&self.ring) };

    return invoke(taking, &input);
}

pub fn complete(self: *Self) void {
    self.countersCall(completing);
}

pub fn drain(self: *Self) void {
    self.countersCall(draining);
}

pub fn stop(self: *Self) void {
    var counters: []u32 = &self.counters;
    const input: std.meta.Child(stopping.Input) = .{ .counters = @ptrCast(&counters) };

    invoke(stopping, &input);
}

inline fn countersCall(self: *Self, comptime entry: type) entry.Output {
    var counters: []u32 = &self.counters;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeValue(empty.allocator(), @ptrCast(&counters)) catch unreachable;
}

inline fn invoke(comptime entry: type, input: entry.Input) entry.Output {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), input) catch unreachable;
}
