const std = @import("std");
const zx = @import("zx");
const Layout = @import("../layout.zig");
const generated = @import("rx_options").generated_graph;
const Self = @This();
const Range = struct { first: usize, end: usize, next: ?u32 };

layout: *const Layout,
count: usize,
range: Range,
pub fn init(layout: *const Layout, first: u32) Self {
    if (comptime generated) {
        const result = invoke(@import("generated_rx_store_initializer_fields"), layout, first);

        return .{ .layout = layout, .count = @intCast(result.count), .range = convert(result.range) };
    }

    var count: usize = 0;
    var fragment: ?u32 = first;

    while (fragment) |row| : (fragment = layout.next[row]) {
        count += @intCast(layout.offsets[row + 1] - layout.offsets[row]);
    }

    return .{ .layout = layout, .count = count, .range = seedRun(layout, first) };
}

pub fn next(self: *Self) ?Range {
    while (self.range.first == self.range.end) {
        const fragment = self.range.next orelse return null;

        self.range = run(self.layout, fragment);

        if (comptime generated) {
            if (self.range.first == self.range.end) return null;

            break;
        }
    }

    const range = self.range;

    self.range.first = range.end;

    return range;
}

fn run(layout: *const Layout, first: u32) Range {
    if (comptime generated) return convert(invoke(@import("generated_rx_store_initializer_range"), layout, first));

    return seedRun(layout, first);
}

fn seedRun(layout: *const Layout, row: usize) Range {
    return .{ .first = @intCast(layout.offsets[row]), .end = @intCast(layout.offsets[row + 1]), .next = layout.next[row] };
}

fn convert(range: anytype) Range {
    return .{ .first = @intCast(range.first), .end = @intCast(range.end), .next = range.next };
}

fn invoke(comptime rule: type, layout: *const Layout, first: u32) @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload {
    const input: std.meta.Child(rule.Input) = .{ .layout = &.{ .offsets = layout.offsets, .next = layout.next }, .first = first };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}
