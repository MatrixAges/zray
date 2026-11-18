const Lock = @import("../lock.zig");
const memory = @import("memory");
const Self = @This();

tags: [64]u8 = undefined,
local: []const u8 = &.{},
count: usize = 0,
// Lock packages may interleave the two variants. Lend their tags in bounded
// windows so a read-only lookup never needs a heap allocation or table copy.
pub fn take(self: *Self, remaining: []const Lock.Package) []const Lock.Package {
    const rows = remaining[0..@min(self.tags.len, remaining.len)];

    self.count = 0;

    for (rows, self.tags[0..rows.len]) |row, *tag| {
        tag.* = @intFromBool(row.source == .workspace);
        self.count += tag.*;
    }

    self.local = if (self.count == rows.len) &.{} else self.tags[0..rows.len];

    return rows;
}

pub fn paths(rows: []const Lock.Package) memory.TextColumn {
    var sample: Lock.Package = undefined;
    sample.source = .{ .workspace = undefined };

    return memory.borrowProjectedText(rows, &sample, &sample.source.workspace);
}
