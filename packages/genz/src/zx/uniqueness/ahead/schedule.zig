const std = @import("std");
const zx = @import("zx");
const changing = @import("generated_uniqueness_ahead_transition");
const resetting = @import("generated_uniqueness_ahead_reset");
pub const Event = @FieldType(std.meta.Child(changing.Input), "event");

pub fn transition(words_arg: []u32, index: usize, event: Event) bool {
    var words = words_arg;
    const input: std.meta.Child(changing.Input) = .{ .words = @ptrCast(&words), .index = index, .event = event };

    return invoke(changing, &input);
}

pub fn reset(words_arg: []u32, dirty: []bool) void {
    var words = words_arg;
    var flags = std.mem.sliceAsBytes(dirty);
    const input: std.meta.Child(resetting.Input) = .{ .words = @ptrCast(&words), .dirty = @ptrCast(&flags), .count = words.len };

    invoke(resetting, &input);
}

inline fn invoke(comptime entry: type, input: entry.Input) entry.Output {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), input) catch unreachable;
}
