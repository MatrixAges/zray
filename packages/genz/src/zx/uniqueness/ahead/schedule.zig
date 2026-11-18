const std = @import("std");
const zx = @import("zx");
const scanning = @import("generated_uniqueness_ahead_scan");
const changing = @import("generated_uniqueness_ahead_transition");
const taking = @import("generated_uniqueness_ahead_take");
const resetting = @import("generated_uniqueness_ahead_reset");
pub const Event = @FieldType(std.meta.Child(changing.Input), "event");

pub fn scan(words: []u32, dirty: []bool, recursive: []const bool, indices: []const u64, first: usize, workers: usize) ?usize {
    const flags = std.mem.sliceAsBytes(dirty);

    const input: std.meta.Child(scanning.Input) = .{
        .words = @ptrCast(&words),
        .dirty = @ptrCast(&flags),
        .recursive = recursive,
        .indices = indices,
        .first = first,
        .workers = workers,
    };

    return @intCast(invoke(scanning, &input) orelse return null);
}

pub fn transition(words: []u32, index: usize, event: Event) bool {
    const input: std.meta.Child(changing.Input) = .{ .words = @ptrCast(&words), .index = index, .event = event };

    return invoke(changing, &input);
}

pub fn take(words: []u32, dirty: []bool, index: usize) std.mem.Allocator.Error!bool {
    const flags = std.mem.sliceAsBytes(dirty);
    const input: std.meta.Child(taking.Input) = .{ .words = @ptrCast(&words), .dirty = @ptrCast(&flags), .index = index };

    return switch (invoke(taking, &input)) {
        .Missing => false,
        .Ready => true,
        .Failed => error.OutOfMemory,
        .Pending => unreachable,
    };
}

pub fn reset(words: []u32, dirty: []bool) void {
    const flags = std.mem.sliceAsBytes(dirty);
    const input: std.meta.Child(resetting.Input) = .{ .words = @ptrCast(&words), .dirty = @ptrCast(&flags), .count = words.len };

    invoke(resetting, &input);
}

inline fn invoke(comptime entry: type, input: entry.Input) entry.Output {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), input) catch unreachable;
}
