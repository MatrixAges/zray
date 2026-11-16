const std = @import("std");
const memory = @import("zxc_standard").memory;
const Map = @import("frontend").project.source_index.Map;
const Initializer = @import("../modules.zig").StoreInitializer;
const Self = @This();

keys: memory.TextColumn,
modules: memory.TextColumn,
types: memory.TextColumn,
buckets: []u64,
count: usize,
pub fn init(allocator: std.mem.Allocator, rows: []const Initializer) std.mem.Allocator.Error!Self {
    return .{
        .keys = memory.borrowTextColumn("identity", rows),
        .modules = memory.borrowTextColumn("module_name", rows),
        .types = memory.borrowTextColumn("type_name", rows),
        .buckets = if (rows.len > 1) try Map.bucketsFor(allocator, rows.len) else &.{},
        .count = rows.len,
    };
}

pub fn input(self: *const Self, comptime Target: type) Target {
    return .{
        .keys = @ptrCast(&self.keys),
        .modules = @ptrCast(&self.modules),
        .types = @ptrCast(&self.types),
        .buckets = @ptrCast(&self.buckets),
        .capacity = self.buckets.len,
        .count = self.count,
    };
}
