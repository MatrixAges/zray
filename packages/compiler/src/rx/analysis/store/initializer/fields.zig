const Layout = @import("../layout.zig");
const Self = @This();
const Range = struct { first: usize, end: usize, next: ?u32 };

layout: *const Layout,
count: usize,
range: Range,
pub fn init(layout: *const Layout, first: u32) Self {
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

        self.range = seedRun(self.layout, fragment);
    }

    const range = self.range;

    self.range.first = range.end;

    return range;
}

fn seedRun(layout: *const Layout, row: usize) Range {
    return .{ .first = @intCast(layout.offsets[row]), .end = @intCast(layout.offsets[row + 1]), .next = layout.next[row] };
}
