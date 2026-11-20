const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_uniqueness_visit_select") else void;
pub const Origin = if (generated) entry.Output else enum { Cached, Ahead, Analyze };

pub fn choose(cached: bool, ahead: bool) Origin {
    if (!generated) return if (cached) .Cached else if (ahead) .Ahead else .Analyze;

    const input: std.meta.Child(entry.Input) = .{ .cached = cached, .ahead = ahead };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}
