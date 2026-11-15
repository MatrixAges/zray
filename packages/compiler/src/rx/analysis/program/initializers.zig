const std = @import("std");
const project = @import("frontend").project;
const Index = project.source_index.Owned;
const Entry = project.compiled.StoreInitializer;
const Self = @This();

rows: std.ArrayList(Entry) = .empty,
checked_prefix: []const Entry = &.{},
index: Index = .{},
scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
pub fn deinit(self: *Self) void {
    self.scratch.deinit();
}

pub fn add(self: *Self, allocator: std.mem.Allocator, value: Entry) std.mem.Allocator.Error!?Entry {
    const row = self.rows.items.len;

    try self.rows.ensureUnusedCapacity(allocator, 1);
    if (try self.index.register(self.scratch.allocator(), value.identity, row)) |previous| return self.rows.items[previous];

    self.rows.appendAssumeCapacity(value);

    return null;
}

pub fn alreadyChecked(self: *const Self, values: []const Entry) bool {
    return values.len == 0 or (values.len == self.checked_prefix.len and values.ptr == self.checked_prefix.ptr);
}
